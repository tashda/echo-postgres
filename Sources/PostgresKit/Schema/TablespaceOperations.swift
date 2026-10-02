
/// Tablespace DDL operations.
public extension PostgresAdminClient {

    /// Create a tablespace.
    @discardableResult
    func createTablespace(
        name: String,
        location: String,
        owner: String? = nil,
        options: [String: String]? = nil
    ) async throws -> Int {
        var parts: [String] = ["CREATE TABLESPACE \(client.quoteIdentifier(name))"]
        if let owner { parts.append("OWNER \(client.quoteIdentifier(owner))") }
        parts.append("LOCATION \(client.quoteLiteral(location))")
        if let options, !options.isEmpty {
            let optionList = options.map { "\($0.key) = \($0.value)" }.joined(separator: ", ")
            parts.append("WITH (\(optionList))")
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Change a tablespace's owner.
    @discardableResult
    func alterTablespaceOwner(name: String, newOwner: String) async throws -> Int {
        let sql = "ALTER TABLESPACE \(client.quoteIdentifier(name)) OWNER TO \(client.quoteIdentifier(newOwner))"
        return try await client.executeDDL(sql)
    }

    /// Rename a tablespace.
    @discardableResult
    func alterTablespaceRename(name: String, newName: String) async throws -> Int {
        let sql = "ALTER TABLESPACE \(client.quoteIdentifier(name)) RENAME TO \(client.quoteIdentifier(newName))"
        return try await client.executeDDL(sql)
    }

    /// Drop a tablespace.
    @discardableResult
    func dropTablespace(name: String, ifExists: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP TABLESPACE"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        return try await client.executeDDL(parts.joined(separator: " "))
    }
}
