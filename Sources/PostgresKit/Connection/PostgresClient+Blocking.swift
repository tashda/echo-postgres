import Foundation
import PostgresNIO

/// A session that holds a lock another session is waiting for.
public struct PostgresBlockingSession: Sendable, Equatable {
    public let pid: Int32
    public let user: String?
    public let applicationName: String?
    /// The blocker's current or last statement, shortened to 200 characters.
    public let query: String?
    /// `active`, `idle in transaction`, …
    public let state: String?
    /// When the blocker's transaction began.
    public let transactionStartedAt: Date?
}

extension PostgresClient {
    /// The sessions blocking the backend `pid` (`pg_blocking_pids`); empty when it is not waiting
    /// for a lock. Runs on a pooled connection, so it works while `pid` is busy; one short query.
    public func blockingSessions(of pid: Int32) async throws -> [PostgresBlockingSession] {
        var binds = PostgresBindings()
        binds.append(pid)
        let sql = """
            SELECT a.pid, a.usename::text, a.application_name, left(a.query, 200), a.state,
                   extract(epoch FROM a.xact_start)::float8
            FROM pg_stat_activity a
            WHERE a.pid = ANY(pg_blocking_pids($1))
            ORDER BY a.xact_start NULLS LAST
            """
        do {
            let rows = try await wire.query(WireQuery(sql: sql, binds: binds))
            var sessions: [PostgresBlockingSession] = []
            for try await row in rows.decode((Int32, String?, String?, String?, String?, Double?).self) {
                sessions.append(PostgresBlockingSession(
                    pid: row.0, user: row.1, applicationName: row.2, query: row.3, state: row.4,
                    transactionStartedAt: row.5.map { Date(timeIntervalSince1970: $0) }
                ))
            }
            return sessions
        } catch {
            throw PostgresError.from(error)
        }
    }
}
