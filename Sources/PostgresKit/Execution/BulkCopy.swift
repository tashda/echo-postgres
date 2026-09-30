import Foundation
import Logging
import NIOCore
import PostgresWire

/// High-level bulk data movement (COPY) operations.
public struct PostgresBulkCopy: @unchecked Sendable {
    public struct Options: Sendable {
        public var chunkSizeBytes: Int = 64 * 1024
        /// Unused since `copyIn` uses the COPY protocol; kept for source compatibility.
        public var insertBatchSize: Int = 500
        /// NULL string used when the statement does not specify one.
        public var nullString: String? = nil
        public init(chunkSizeBytes: Int = 64 * 1024, insertBatchSize: Int = 500, nullString: String? = nil) {
            self.chunkSizeBytes = chunkSizeBytes
            self.insertBatchSize = insertBatchSize
            self.nullString = nullString
        }
    }

    private let client: PostgresClient
    private let logger: Logger
    private let options: Options

    public init(client: PostgresClient, logger: Logger, options: Options = .init()) {
        self.client = client
        self.logger = logger
        self.options = options
    }

    /// Run `COPY table|(query) TO STDOUT` in CSV or text format and stream the output.
    ///
    /// Rows are read with a regular query and rendered by ``PostgresBinaryFormatter``, so every type
    /// is written in its Postgres text form; NULL and empty strings stay distinguishable.
    public func copyOut(sql: String) async throws -> AsyncThrowingStream<Data, Error> {
        let parsed = try CopyStatement.parse(sql: sql)
        guard parsed.direction == .out else { throw PostgresKitError.notSupported("Expected COPY ... TO STDOUT") }

        let chunkSize = max(16 * 1024, options.chunkSizeBytes)
        let writer = CSVWriter(delimiter: parsed.delimiter, quote: parsed.quote, nullString: parsed.nullString ?? options.nullString ?? "")
        let client = self.client
        return AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    let format = parsed.format
                    let delimiter = parsed.delimiter
                    let header = parsed.header
                    let selectSQL = parsed.selectSQL
                    let remainder = try await client.withConnection { connection -> Data in
                        let formatter = PostgresCellFormatter()
                        var buffer = Data()
                        buffer.reserveCapacity(chunkSize)
                        var wroteHeader = false
                        func line(_ fields: [String?]) -> String {
                            format == .csv ? writer.line(fields) : CSVWriter.textLine(fields, delimiter: delimiter)
                        }
                        for try await row in try await connection.simpleQuery(selectSQL) {
                            if header && !wroteHeader {
                                buffer.append(contentsOf: line(row.map { $0.columnName }).utf8)
                                wroteHeader = true
                            }
                            buffer.append(contentsOf: line(row.map { formatter.stringValue(for: $0) }).utf8)
                            if buffer.count >= chunkSize {
                                continuation.yield(buffer)
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        return buffer
                    }
                    if !remainder.isEmpty { continuation.yield(remainder) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: PostgresError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Run `COPY table [(columns)] FROM STDIN` in CSV or text format, streaming `source` to the server
    /// over the COPY protocol. The load is one statement: either every row is stored or none is.
    ///
    /// CSV input is parsed client-side (RFC 4180, including quoted multi-line fields) and re-encoded
    /// as COPY text; text input is passed through unchanged.
    public func copyIn<S: AsyncSequence>(sql: String, source: S) async throws where S.Element == Data {
        let parsed = try CopyStatement.parse(sql: sql)
        guard parsed.direction == .in, let table = parsed.table else {
            throw PostgresKitError.notSupported("Expected COPY table FROM STDIN")
        }
        let chunkSize = max(16 * 1024, options.chunkSizeBytes)
        let logger = self.logger

        do {
            try await client.wire.withConnection { connection in
                switch parsed.format {
                case .text:
                    guard let delimiter = parsed.delimiter.unicodeScalars.first, parsed.delimiter.unicodeScalars.count == 1 else {
                        throw PostgresKitError.notSupported("COPY delimiter must be a single character")
                    }
                    guard parsed.nullString == nil || parsed.nullString == "\\N", !parsed.header else {
                        throw PostgresKitError.notSupported("Text-format COPY supports only the default NULL string and no HEADER")
                    }
                    try await connection.copyFrom(schema: parsed.schema, table: table, columns: parsed.columns, delimiter: delimiter == "\t" ? nil : delimiter, logger: logger) { writer in
                        for try await chunk in source where !chunk.isEmpty {
                            try await writer.write(ByteBuffer(bytes: chunk))
                        }
                    }
                case .csv:
                    var converter = try CSVToCopyTextConverter(
                        delimiter: parsed.delimiter,
                        quote: parsed.quote,
                        nullString: parsed.nullString ?? options.nullString,
                        skipHeader: parsed.header
                    )
                    try await connection.copyFrom(schema: parsed.schema, table: table, columns: parsed.columns, logger: logger) { writer in
                        var output: [UInt8] = []
                        output.reserveCapacity(chunkSize)
                        for try await chunk in source {
                            converter.feed(chunk, into: &output)
                            if output.count >= chunkSize {
                                try await writer.write(ByteBuffer(bytes: output))
                                output.removeAll(keepingCapacity: true)
                            }
                        }
                        try converter.finish(into: &output)
                        if !output.isEmpty { try await writer.write(ByteBuffer(bytes: output)) }
                    }
                }
            }
        } catch let error as PostgresKitError {
            throw error
        } catch {
            throw PostgresError.from(error)
        }
    }
}
