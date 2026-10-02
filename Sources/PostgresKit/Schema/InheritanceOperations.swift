
/// High-level table inheritance operations.
public extension PostgresAdminClient {
    /// Add inheritance — make child inherit from parent.
    @discardableResult
    func addInheritance(
        child: String,
        parent: String,
        childSchema: String? = nil,
        parentSchema: String? = nil
    ) async throws -> Int {
        let qualifiedChild = childSchema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(child))" } ?? client.quoteIdentifier(child)
        let qualifiedParent = parentSchema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(parent))" } ?? client.quoteIdentifier(parent)
        let sql = "ALTER TABLE \(qualifiedChild) INHERIT \(qualifiedParent)"
        return try await client.executeDDL(sql)
    }

    /// Remove inheritance.
    @discardableResult
    func dropInheritance(
        child: String,
        parent: String,
        childSchema: String? = nil,
        parentSchema: String? = nil
    ) async throws -> Int {
        let qualifiedChild = childSchema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(child))" } ?? client.quoteIdentifier(child)
        let qualifiedParent = parentSchema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(parent))" } ?? client.quoteIdentifier(parent)
        let sql = "ALTER TABLE \(qualifiedChild) NO INHERIT \(qualifiedParent)"
        return try await client.executeDDL(sql)
    }
}
