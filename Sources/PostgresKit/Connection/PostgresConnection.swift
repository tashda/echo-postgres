import Foundation
import Logging
import PGLibpq
import Synchronization

/// One leased connection (from ``PostgresClient/withConnection(_:)``): every call runs on the same
/// backend.
public final class PostgresConnection: Sendable {
    let connection: PGConnection
    let logger: Logger
    /// The rows of the last statement, while they may still be unread (see
    /// ``PostgresClient/withConnection(_:)``).
    let lastRows = Mutex(WeakResultStream())

    init(connection: PGConnection, logger: Logger) {
        self.connection = connection
        self.logger = logger
    }

    /// Runs SQL (several statements are allowed; the rows are the last result set's) and streams
    /// its rows.
    public func simpleQuery(_ sql: String) async throws -> PostgresRows {
        try await prepareForStatement()
        do {
            try await connection.send(sql)
        } catch {
            throw PostgresError.from(error)
        }
        return try await rows(PostgresResultStream(connection: connection))
    }

    /// Runs one statement with `$n` parameters and streams its rows.
    public func query(_ sql: String, binds: [PostgresBind] = []) async throws -> PostgresRows {
        guard !binds.isEmpty else { return try await simpleQuery(sql) }
        try await prepareForStatement()
        do {
            try await connection.send(sql, parameters: binds.map(\.parameter))
        } catch {
            throw PostgresError.from(error)
        }
        return try await rows(PostgresResultStream(connection: connection))
    }

    private func rows(_ stream: PostgresResultStream) async throws -> PostgresRows {
        lastRows.withLock { $0.stream = stream }
        try await stream.awaitFirstResult()
        return PostgresRows(stream: stream)
    }

    /// Runs one statement and collects all rows plus the command tag (`UPDATE 3`, `CREATE TABLE`).
    public func queryResult(_ sql: String, binds: [PostgresBind] = []) async throws -> PostgresQueryResult {
        try await prepareForStatement()
        do {
            let results = binds.isEmpty
                ? try await connection.execute(sql)
                : try await connection.execute(sql, parameters: binds.map(\.parameter))
            return try Self.collect(results)
        } catch {
            throw PostgresError.from(error)
        }
    }

    /// Runs one statement with `$n` parameters and returns all its rows.
    public func queryPreparedRows(_ sql: String, binds: [PostgresBind] = []) async throws -> [PostgresRow] {
        try await queryResult(sql, binds: binds).rows
    }

    /// Notifications for `channel` while this connection is leased (run `LISTEN` first). For
    /// listening that outlives a lease use ``PostgresClient/notifier``.
    public func notifications() async -> [PostgresNotification] {
        await connection.takeNotifications().map { PostgresNotification(channel: $0.channel, payload: $0.payload, pid: $0.pid) }
    }

    /// Whether the connection is still open.
    public var isOpen: Bool { get async { await connection.isOpen } }

    /// Rows of the last result set, the command tag of the last statement; the first error throws.
    static func collect(_ results: [PGResult]) throws -> PostgresQueryResult {
        var rows: [PostgresRow] = [], current: [PostgresRow] = []
        var tag = ""
        for result in results {
            switch result.status {
            case .error:
                throw result.error.map { PostgresError(server: $0) } ?? PostgresError(message: "The statement failed")
            case .rowsChunk:
                current += (0..<result.rowCount).map { PostgresRow(result: result, index: $0) }
            case .rowsDone:
                current += (0..<result.rowCount).map { PostgresRow(result: result, index: $0) }
                rows = current
                current = []
                tag = result.commandStatus
            default:
                tag = result.commandStatus
            }
        }
        return PostgresQueryResult(metadata: PostgresQueryMetadata(tag: tag), rows: rows)
    }

    /// Rows of an earlier statement nobody read: cancel and drain them.
    private func prepareForStatement() async throws {
        guard await connection.isBusy else { return }
        await PostgresResultStream.finishAbandoned(connection)
    }
}

/// A result stream held weakly (a reader may drop its rows).
struct WeakResultStream: Sendable {
    weak var stream: PostgresResultStream?
}
