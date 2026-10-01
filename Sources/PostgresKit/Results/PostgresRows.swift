import Foundation
import PGLibpq
import Synchronization

/// The rows of one statement, read from the server as they are asked for, in chunks: memory stays
/// bounded by one chunk, and a slow reader slows the server down instead of filling memory.
///
/// Read to the end (or drop the sequence) before the connection's next statement. A sequence
/// dropped early cancels the statement and reads what is left before the connection is used again.
public struct PostgresRows: AsyncSequence, Sendable {
    public typealias Element = PostgresRow
    let stream: PostgresResultStream

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(stream: stream) }

    /// Reads every row into memory.
    public func collect() async throws -> [PostgresRow] {
        var rows: [PostgresRow] = []
        for try await row in self { rows.append(row) }
        return rows
    }

    /// Reads each row as the given types (`rows.decode((String, Int?).self)`).
    public func decode<each T: PostgresTextDecodable>(_ type: (repeat each T).Type) -> AsyncThrowingMapSequence<PostgresRows, (repeat each T)> {
        map { row in try row.decode(type) }
    }

    /// Reads each row's first column as `type`.
    public func decode<T: PostgresTextDecodable>(_ type: T.Type) -> AsyncThrowingMapSequence<PostgresRows, T> {
        map { row in try row.decode(type) }
    }

    /// The column names and types, as soon as the server described them (also with no rows).
    public func columns() async throws -> [PostgresColumn] {
        try await stream.columns()
    }

    /// The results as libpq delivers them (`PGResult` chunks), for a reader that handles whole
    /// chunks (the result grid's spool). Don't mix with row iteration.
    public var chunks: PostgresChunks { PostgresChunks(stream: stream) }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let stream: PostgresResultStream
        var current: PGResult?
        var row = 0

        public mutating func next() async throws -> PostgresRow? {
            while true {
                if let current, row < current.rowCount {
                    defer { row += 1 }
                    return PostgresRow(result: current, index: row)
                }
                guard let chunk = try await stream.nextChunk() else { return nil }
                current = chunk
                row = 0
            }
        }
    }
}

/// Result chunks of one statement (see ``PostgresRows/chunks``).
public struct PostgresChunks: AsyncSequence, Sendable {
    public typealias Element = PGResult
    let stream: PostgresResultStream

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(stream: stream) }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let stream: PostgresResultStream
        public mutating func next() async throws -> PGResult? { try await stream.nextChunk() }
    }
}

/// A result column: name, type and where it comes from.
public struct PostgresColumn: Sendable, Equatable {
    public let name: String
    public let typeOID: UInt32
    public let typeModifier: Int32
    /// The table and column number it comes from; 0 for computed columns.
    public let tableOID: UInt32
    public let tableColumn: Int

    init(result: PGResult, column: Int) {
        name = result.columnName(column)
        typeOID = result.columnType(column)
        typeModifier = result.columnTypeModifier(column)
        let source = result.columnSource(column)
        tableOID = source.tableOID
        tableColumn = source.column
    }

    public static func columns(of result: PGResult) -> [PostgresColumn] {
        (0..<result.columnCount).map { PostgresColumn(result: result, column: $0) }
    }
}

/// Reads one statement's results off a connection and reports when it is done (once). Results
/// are pulled: nothing is read from the socket until the reader asks.
final class PostgresResultStream: Sendable {
    typealias Completion = @Sendable (_ connection: PGConnection, _ error: (any Error)?, _ commandTag: String?) async -> Void

    let connection: PGConnection
    private let mapError: @Sendable (any Error) -> any Error
    private struct State {
        var completion: Completion?
        var lateCompletions: [@Sendable ((any Error)?) async -> Void] = []
        var finished = false
        var columns: [PostgresColumn]?
        var buffered: PGResult?
        var commandTag: String?
    }
    private let state = Mutex(State())

    init(connection: PGConnection, mapError: @escaping @Sendable (any Error) -> any Error = PostgresError.fromDriver, completion: Completion? = nil) {
        self.connection = connection
        self.mapError = mapError
        state.withLock { $0.completion = completion }
    }

    /// Whether the rows have all been read (or the statement failed).
    var isFinished: Bool { state.withLock { $0.finished } }

    /// Runs `body` when the statement is done (now, if it already is).
    func whenFinished(_ body: @escaping @Sendable ((any Error)?) async -> Void) async {
        let finishedAlready = state.withLock { state -> Bool in
            if !state.finished { state.lateCompletions.append(body) }
            return state.finished
        }
        if finishedAlready { await body(nil) }
    }

    deinit {
        let pending = state.withLock { state -> (Completion?, [@Sendable ((any Error)?) async -> Void])? in
            state.finished ? nil : (state.completion, state.lateCompletions)
        }
        guard let pending else { return }
        // Dropped before the end: stop the statement and read what is left, then report.
        let connection = self.connection
        Task(name: "postgres-rows-abandoned") {
            await PostgresResultStream.finishAbandoned(connection)
            await pending.0?(connection, nil, nil)
            for late in pending.1 { await late(nil) }
        }
    }

    /// Rows nobody will read: a statement still returning rows is cancelled (fast, even for a huge
    /// result); a command (DDL, NOTIFY …) is left to finish. Then everything left is read away.
    static func finishAbandoned(_ connection: PGConnection) async {
        while await connection.isBusy {
            guard let result = try? await connection.nextResult() else { return }
            if result.status == .rowsChunk {
                try? await connection.cancel()
                try? await connection.drain()
                return
            }
        }
    }

    /// The next result with rows (a chunk, or the last part of the result set); nil at the end.
    func nextChunk() async throws -> PGResult? {
        if let buffered = state.withLock({ state -> PGResult? in defer { state.buffered = nil }; return state.buffered }) {
            return buffered
        }
        guard !state.withLock({ $0.finished }) else { return nil }
        do {
            while let result = try await connection.nextResult() {
                switch result.status {
                case .rowsChunk, .rowsDone:
                    state.withLock { if $0.columns == nil { $0.columns = PostgresColumn.columns(of: result) } }
                    if result.status == .rowsDone {
                        // The command tag comes with the last part; keep reading to the end.
                        try await finish(commandTag: result.commandStatus)
                    }
                    return result
                case .commandDone, .emptyQuery:
                    try await finish(commandTag: result.commandStatus)
                    return nil
                case .error:
                    let error = result.error.map { PostgresError(server: $0) } ?? PostgresError(message: "The statement failed")
                    try? await connection.drain()
                    await report(error: error)
                    throw error
                case .copyIn, .copyOut, .other:
                    continue
                }
            }
            await report(error: nil, commandTag: nil)
            return nil
        } catch {
            let mapped = mapError(error)
            await report(error: mapped)
            throw mapped
        }
    }

    /// The command tag, once the statement finished.
    var commandTag: String? { state.withLock { $0.commandTag } }

    /// The columns, reading ahead to the first result if needed.
    func columns() async throws -> [PostgresColumn] {
        if let columns = state.withLock({ $0.columns }) { return columns }
        let first = try await nextChunk()
        if let first { state.withLock { $0.buffered = first } }
        return state.withLock { $0.columns } ?? []
    }

    /// Reads what follows the end of the result set (nothing for one statement), then reports.
    private func finish(commandTag: String) async throws {
        do {
            try await connection.drain()
        } catch {
            let mapped = mapError(error)
            await report(error: mapped)
            throw mapped
        }
        await report(error: nil, commandTag: commandTag)
    }

    private func report(error: (any Error)?, commandTag: String? = nil) async {
        let pending = state.withLock { state -> (Completion?, [@Sendable ((any Error)?) async -> Void])? in
            defer { state.finished = true }
            if let commandTag { state.commandTag = commandTag }
            guard !state.finished else { return nil }
            defer { state.lateCompletions.removeAll() }
            return (state.completion, state.lateCompletions)
        }
        guard let pending else { return }
        await pending.0?(connection, error, commandTag)
        for late in pending.1 { await late(error) }
    }
}
