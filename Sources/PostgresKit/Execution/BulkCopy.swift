import Foundation
import Logging
import PGLibpq

/// High-level bulk data movement (COPY) operations, through libpq's COPY protocol: every format
/// (CSV, text, binary) goes to and from the server unchanged.
public struct PostgresBulkCopy: Sendable {
    public struct Options: Sendable {
        /// Size of the chunks ``copyOut(sql:)`` yields.
        public var chunkSizeBytes: Int = 64 * 1024
        /// Unused since `copyIn` uses the COPY protocol; kept for source compatibility.
        public var insertBatchSize: Int = 500
        /// Unused: the statement's own `NULL` option applies; kept for source compatibility.
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

    /// Runs `COPY table|(query) TO STDOUT` (any format) and streams the server's output.
    public func copyOut(sql: String) async throws -> AsyncThrowingStream<Data, Error> {
        let parsed = try CopyStatement.parse(sql: sql)
        guard parsed.direction == .out else { throw PostgresKitError.notSupported("Expected COPY ... TO STDOUT") }
        let chunkSize = max(16 * 1024, options.chunkSizeBytes)
        let client = self.client
        return AsyncThrowingStream<Data, Error> { continuation in
            let task = Task(name: "postgres-copy-out") {
                do {
                    try await client.withConnection { connection in
                        try await PostgresBulkCopy.copyOut(sql, on: connection.connection, chunkSize: chunkSize) { continuation.yield($0) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: PostgresError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs `COPY table [(columns)] FROM STDIN` (any format), streaming `source` to the server. The
    /// load is one statement: either every row is stored or none is.
    public func copyIn<S: AsyncSequence>(sql: String, source: S) async throws where S.Element == Data {
        let parsed = try CopyStatement.parse(sql: sql)
        guard parsed.direction == .in, parsed.table != nil else {
            throw PostgresKitError.notSupported("Expected COPY table FROM STDIN")
        }
        do {
            try await client.withConnection { connection in
                try await PostgresBulkCopy.copyIn(sql, on: connection.connection, source: source)
            }
        } catch {
            throw PostgresError.from(error)
        }
    }

    /// COPY TO STDOUT on one connection, handing over chunks of about `chunkSize` bytes.
    static func copyOut(_ sql: String, on connection: PGConnection, chunkSize: Int, yield: (Data) -> Void) async throws {
        try await connection.send(sql, chunkSize: 1)
        guard let start = try await connection.nextResult() else { throw PostgresError(message: "COPY returned nothing") }
        guard start.status == .copyOut else {
            try? await connection.drain()
            throw start.error.map { PostgresError(server: $0) } ?? PostgresError(message: "Expected COPY ... TO STDOUT")
        }
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        while let row = try await connection.getCopyData() {
            buffer.append(row)
            if buffer.count >= chunkSize {
                yield(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { yield(buffer) }
        try await finish(on: connection)
    }

    /// COPY FROM STDIN on one connection. A failure while reading `source` aborts the COPY.
    static func copyIn<S: AsyncSequence>(_ sql: String, on connection: PGConnection, source: S) async throws where S.Element == Data {
        try await connection.send(sql, chunkSize: 1)
        guard let start = try await connection.nextResult() else { throw PostgresError(message: "COPY returned nothing") }
        guard start.status == .copyIn else {
            try? await connection.drain()
            throw start.error.map { PostgresError(server: $0) } ?? PostgresError(message: "Expected COPY table FROM STDIN")
        }
        do {
            for try await chunk in source where !chunk.isEmpty {
                try await connection.putCopyData(chunk)
            }
        } catch {
            try await connection.endCopy(failing: "Echo stopped the import: \(error.localizedDescription)")
            try? await connection.drain()
            throw error
        }
        try await connection.endCopy()
        try await finish(on: connection)
    }

    /// Reads the COPY's final result; its error, if any, throws.
    private static func finish(on connection: PGConnection) async throws {
        var failure: PostgresError?
        while let result = try await connection.nextResult() {
            if result.status == .error, failure == nil { failure = result.error.map { PostgresError(server: $0) } }
        }
        if let failure { throw failure }
    }
}
