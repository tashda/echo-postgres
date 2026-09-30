import Foundation
import Logging
import PostgresWire

public final class PostgresConnection: @unchecked Sendable {
    private let wire: WireConnection
    private let logger: Logger
    private let cache: StatementCache
    private let serverCache: PreparedServerCache

    init(wireConnection: WireConnection, logger: Logger, cache: StatementCache, serverCache: PreparedServerCache) {
        self.wire = wireConnection
        self.logger = logger
        self.cache = cache
        self.serverCache = serverCache
    }

    @discardableResult
    public func simpleQuery(_ sql: String) async throws -> WireRowSequence {
        return try await wire.query(WireQuery(sql: sql), logger: logger)
    }

    /// Run one statement and collect all rows plus the command tag (`UPDATE 3`, `CREATE TABLE`, …).
    public func queryResult(_ sql: String) async throws -> WireQueryResult {
        try await wire.queryResult(sql)
    }

    /// Run one statement with bind parameters (`$1`, `$2`, …) and stream its rows.
    public func query(_ sql: String, binds: [PGData] = []) async throws -> WireRowSequence {
        if binds.isEmpty {
            return try await wire.query(WireQuery(sql: sql), logger: logger)
        }
        let statement = try await wire.prepare(sql)
        cache.insert(PreparedStatementInfo(sql: sql, parameterCount: binds.count, handle: statement))
        return try await wire.execute(prepared: statement, binds: binds, logger: logger)
    }

    // MARK: - Notifications

    @discardableResult
    public func addNotificationListener(
        channel: String,
        handler: @escaping @Sendable (PostgresNotification) -> Void
    ) -> WireConnection.WireListenToken {
        wire.addNotificationListener(channel: channel) { channel, payload, pid in
            handler(PostgresNotification(channel: channel, payload: payload, pid: pid))
        }
    }

    public func waitForClose() async {
        await wire.waitForClose()
    }

    // Optional server-side prepared execution that returns all rows in memory.
    // Uses a per-connection server prepare cache keyed by SQL + parameter OIDs.
    public func queryPreparedRows(_ sql: String, binds: [PGData] = []) async throws -> [PostgresRow] {
        let types = binds.map { $0.type }
        let key = ServerPrepareKey.make(sql: sql, types: types)
        if let prepared = await serverCache.lookup(key) {
            do {
                return try await wire.executePreparedRows(prepared, binds: binds)
            } catch let err as PSQLError {
                if let state = err.serverInfo?[.sqlState], state == "26000" {
                    await serverCache.remove(key)
                    let fresh = try await wire.prepareQuery(sql)
                    await serverCache.insert(key, prepared: fresh)
                    return try await wire.executePreparedRows(fresh, binds: binds)
                }
                throw err
            }
        } else {
            let prepared = try await wire.prepareQuery(sql)
            await serverCache.insert(key, prepared: prepared)
            return try await wire.executePreparedRows(prepared, binds: binds)
        }
    }
}
