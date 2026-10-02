
/// Logical replication DDL operations.
public extension PostgresReplicationClient {

    // MARK: - Publication Operations

    /// Create a logical replication publication.
    @discardableResult
    func createPublication(
        name: String,
        forAllTables: Bool = false,
        tables: [String]? = nil,
        operations: [String]? = nil
    ) async throws -> Int {
        var parts: [String] = ["CREATE PUBLICATION \(client.quoteIdentifier(name))"]

        if forAllTables {
            parts.append("FOR ALL TABLES")
        } else if let tables, !tables.isEmpty {
            parts.append("FOR TABLE \(tables.map(client.quoteIdentifier).joined(separator: ", "))")
        }

        if let operations, !operations.isEmpty {
            let publishValue = operations.map { $0.lowercased() }.joined(separator: ", ")
            parts.append("WITH (publish = \(client.quoteLiteral(publishValue)))")
        }

        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Add tables to an existing publication.
    @discardableResult
    func alterPublicationAddTables(name: String, tables: [String]) async throws -> Int {
        let tableList = tables.map(client.quoteIdentifier).joined(separator: ", ")
        let sql = "ALTER PUBLICATION \(client.quoteIdentifier(name)) ADD TABLE \(tableList)"
        return try await client.executeDDL(sql)
    }

    /// Remove tables from an existing publication.
    @discardableResult
    func alterPublicationDropTables(name: String, tables: [String]) async throws -> Int {
        let tableList = tables.map(client.quoteIdentifier).joined(separator: ", ")
        let sql = "ALTER PUBLICATION \(client.quoteIdentifier(name)) DROP TABLE \(tableList)"
        return try await client.executeDDL(sql)
    }

    /// Change which DML operations a publication publishes.
    @discardableResult
    func alterPublicationSetOperations(name: String, operations: [String]) async throws -> Int {
        let publishValue = operations.map { $0.lowercased() }.joined(separator: ", ")
        let sql = "ALTER PUBLICATION \(client.quoteIdentifier(name)) SET (publish = \(client.quoteLiteral(publishValue)))"
        return try await client.executeDDL(sql)
    }

    /// Drop a publication.
    @discardableResult
    func dropPublication(name: String, ifExists: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP PUBLICATION"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    // MARK: - Subscription Operations

    /// Create a logical replication subscription.
    @discardableResult
    func createSubscription(
        name: String,
        connectionString: String,
        publications: [String],
        enabled: Bool = true,
        copyData: Bool = true,
        slotName: String? = nil,
        synchronousCommit: String? = nil
    ) async throws -> Int {
        let pubList = publications.map(client.quoteIdentifier).joined(separator: ", ")
        var parts: [String] = [
            "CREATE SUBSCRIPTION \(client.quoteIdentifier(name))",
            "CONNECTION \(client.quoteLiteral(connectionString))",
            "PUBLICATION \(pubList)"
        ]

        var withClauses: [String] = []
        if !enabled { withClauses.append("enabled = false") }
        if !copyData { withClauses.append("copy_data = false") }
        if let slotName { withClauses.append("slot_name = \(client.quoteLiteral(slotName))") }
        if let synchronousCommit { withClauses.append("synchronous_commit = \(client.quoteLiteral(synchronousCommit))") }

        if !withClauses.isEmpty {
            parts.append("WITH (\(withClauses.joined(separator: ", ")))")
        }

        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Enable or disable a subscription.
    @discardableResult
    func alterSubscriptionEnable(name: String, enable: Bool) async throws -> Int {
        let action = enable ? "ENABLE" : "DISABLE"
        let sql = "ALTER SUBSCRIPTION \(client.quoteIdentifier(name)) \(action)"
        return try await client.executeDDL(sql)
    }

    /// Refresh the subscription's table list from the publisher.
    @discardableResult
    func alterSubscriptionRefresh(name: String, copyData: Bool = false) async throws -> Int {
        let sql = "ALTER SUBSCRIPTION \(client.quoteIdentifier(name)) REFRESH PUBLICATION WITH (copy_data = \(copyData))"
        return try await client.executeDDL(sql)
    }

    /// Change which publications a subscription subscribes to.
    @discardableResult
    func alterSubscriptionSetPublication(name: String, publications: [String]) async throws -> Int {
        let pubList = publications.map(client.quoteIdentifier).joined(separator: ", ")
        let sql = "ALTER SUBSCRIPTION \(client.quoteIdentifier(name)) SET PUBLICATION \(pubList)"
        return try await client.executeDDL(sql)
    }

    /// Drop a subscription.
    @discardableResult
    func dropSubscription(name: String, ifExists: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP SUBSCRIPTION"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        return try await client.executeDDL(parts.joined(separator: " "))
    }
}
