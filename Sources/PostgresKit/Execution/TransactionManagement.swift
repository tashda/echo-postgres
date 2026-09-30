import PostgresWire

/// Transaction lifecycle management on the pooled client.
///
/// These methods send each statement through the pool, so `BEGIN`, the work and `COMMIT` can each
/// land on a different connection — the transaction does not cover the work, and a connection can be
/// returned to the pool with a transaction still open. They are kept for source compatibility only.
/// Use ``PostgresClient/withTransaction(isolation:readOnly:_:)``, the connection-level
/// `beginTransaction()` / `commit()` inside ``PostgresClient/withConnection(_:)``, or a
/// ``PostgresSessionConnection``.
public extension PostgresTransactionClient {
    /// Run `body` inside a transaction on one leased connection. See ``PostgresClient/withTransaction(isolation:readOnly:_:)``.
    func withTransaction<T>(
        isolation: PostgresIsolationLevel? = nil,
        readOnly: Bool = false,
        _ body: @Sendable (PostgresConnection) async throws -> T
    ) async throws -> T {
        try await client.withTransaction(isolation: isolation, readOnly: readOnly, body)
    }

    @available(*, deprecated, message: "Pooled: BEGIN and later statements may run on different connections. Use withTransaction or PostgresSessionConnection.")
    @discardableResult
    func beginTransaction() async throws -> Int {
        return try await client.executeDDL("BEGIN")
    }

    @available(*, deprecated, message: "Pooled: BEGIN and later statements may run on different connections. Use withTransaction or PostgresSessionConnection.")
    @discardableResult
    func beginTransaction(
        isolation: PostgresIsolationLevel,
        readOnly: Bool = false,
        deferrable: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["BEGIN TRANSACTION"]
        parts.append("ISOLATION LEVEL \(isolation.rawValue)")
        if readOnly { parts.append("READ ONLY") }
        if deferrable { parts.append("DEFERRABLE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    @available(*, deprecated, message: "Pooled: may run on a different connection than BEGIN. Use withTransaction or PostgresSessionConnection.")
    @discardableResult
    func commit() async throws -> Int {
        return try await client.executeDDL("COMMIT")
    }

    @available(*, deprecated, message: "Pooled: may run on a different connection than BEGIN. Use withTransaction or PostgresSessionConnection.")
    @discardableResult
    func rollback() async throws -> Int {
        return try await client.executeDDL("ROLLBACK")
    }

    @available(*, deprecated, message: "Pooled: may run on a different connection than BEGIN. Use withTransaction or PostgresSessionConnection.")
    @discardableResult
    func createSavepoint(_ name: String) async throws -> Int {
        return try await client.executeDDL("SAVEPOINT \(client.quoteSimpleIdentifier(name))")
    }

    @available(*, deprecated, message: "Pooled: may run on a different connection than BEGIN. Use withTransaction or PostgresSessionConnection.")
    @discardableResult
    func rollbackToSavepoint(_ name: String) async throws -> Int {
        return try await client.executeDDL("ROLLBACK TO SAVEPOINT \(client.quoteSimpleIdentifier(name))")
    }

    @available(*, deprecated, message: "Pooled: may run on a different connection than BEGIN. Use withTransaction or PostgresSessionConnection.")
    @discardableResult
    func releaseSavepoint(_ name: String) async throws -> Int {
        return try await client.executeDDL("RELEASE SAVEPOINT \(client.quoteSimpleIdentifier(name))")
    }
}
