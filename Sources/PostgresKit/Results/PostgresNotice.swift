import PGLibpq

/// A message the server sent while a statement ran (`RAISE NOTICE`, `RAISE WARNING`, `RAISE INFO`,
/// and the server's own notices such as "table does not exist, skipping").
public struct PostgresNotice: Sendable, Equatable {
    /// `NOTICE`, `WARNING`, `INFO`, `LOG`, `DEBUG`.
    public let severity: String
    public let sqlState: String?
    public let message: String
    public let detail: String?
    public let hint: String?
    /// Where it came from inside server code (`PL/pgSQL function f() line 3 at RAISE`).
    public let context: String?

    init(_ notice: PGServerError) {
        severity = notice.severity ?? "NOTICE"
        sqlState = notice.sqlState
        message = notice.message
        detail = notice.detail
        hint = notice.hint
        context = notice.context
    }
}

extension PostgresSessionConnection {
    /// Notices received since the last call, in order.
    public func takeNotices() async -> [PostgresNotice] {
        await pgConnection.takeNotices().map(PostgresNotice.init)
    }
}

extension PostgresConnection {
    /// Notices received since the last call, in order.
    public func takeNotices() async -> [PostgresNotice] {
        await connection.takeNotices().map(PostgresNotice.init)
    }
}
