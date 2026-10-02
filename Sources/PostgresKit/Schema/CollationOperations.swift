
/// Collation DDL operations.
public extension PostgresAdminClient {

    /// Create a collation.
    @discardableResult
    func createCollation(
        name: String,
        locale: String? = nil,
        lcCollate: String? = nil,
        lcCtype: String? = nil,
        provider: String? = nil,
        schema: String? = nil,
        ifNotExists: Bool = false
    ) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        var parts: [String] = ["CREATE COLLATION"]
        if ifNotExists { parts.append("IF NOT EXISTS") }
        parts.append(qualifiedName)

        var clauses: [String] = []
        if let provider { clauses.append("provider = \(client.quoteLiteral(provider))") }
        if let locale { clauses.append("locale = \(client.quoteLiteral(locale))") }
        if let lcCollate { clauses.append("lc_collate = \(client.quoteLiteral(lcCollate))") }
        if let lcCtype { clauses.append("lc_ctype = \(client.quoteLiteral(lcCtype))") }

        parts.append("(\(clauses.joined(separator: ", ")))")
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Rename a collation.
    @discardableResult
    func alterCollationRename(name: String, newName: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER COLLATION \(qualifiedName) RENAME TO \(client.quoteIdentifier(newName))"
        return try await client.executeDDL(sql)
    }

    /// Change a collation's owner.
    @discardableResult
    func alterCollationOwner(name: String, newOwner: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER COLLATION \(qualifiedName) OWNER TO \(client.quoteIdentifier(newOwner))"
        return try await client.executeDDL(sql)
    }

    /// Move a collation to a different schema.
    @discardableResult
    func alterCollationSetSchema(name: String, newSchema: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER COLLATION \(qualifiedName) SET SCHEMA \(client.quoteIdentifier(newSchema))"
        return try await client.executeDDL(sql)
    }

    /// Refresh a collation's version.
    @discardableResult
    func alterCollationRefreshVersion(name: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER COLLATION \(qualifiedName) REFRESH VERSION"
        return try await client.executeDDL(sql)
    }

    /// Drop a collation.
    @discardableResult
    func dropCollation(name: String, ifExists: Bool = false, cascade: Bool = false, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        var parts: [String] = ["DROP COLLATION"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(qualifiedName)
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }
}
