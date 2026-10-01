
/// Full-text search configuration and dictionary DDL operations.
public extension PostgresAdminClient {

    // MARK: - Text Search Configuration

    /// Create a text search configuration.
    @discardableResult
    func createTextSearchConfiguration(
        name: String,
        parser: String? = nil,
        copy: String? = nil,
        schema: String? = nil
    ) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        var parts: [String] = ["CREATE TEXT SEARCH CONFIGURATION \(qualifiedName)"]
        if let parser {
            parts.append("(PARSER = \(client.quoteIdentifier(parser)))")
        } else if let copy {
            let qualifiedCopy = client.quoteIdentifier(copy)
            parts.append("(COPY = \(qualifiedCopy))")
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Alter a text search configuration mapping for token types.
    @discardableResult
    func alterTextSearchConfigurationMapping(
        name: String,
        tokenTypes: [String],
        dictionary: String,
        schema: String? = nil
    ) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let tokenList = tokenTypes.joined(separator: ", ")
        let sql = "ALTER TEXT SEARCH CONFIGURATION \(qualifiedName) ALTER MAPPING FOR \(tokenList) WITH \(client.quoteIdentifier(dictionary))"
        return try await client.executeDDL(sql)
    }

    /// Rename a text search configuration.
    @discardableResult
    func alterTextSearchConfigurationRename(name: String, newName: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER TEXT SEARCH CONFIGURATION \(qualifiedName) RENAME TO \(client.quoteIdentifier(newName))"
        return try await client.executeDDL(sql)
    }

    /// Change a text search configuration's owner.
    @discardableResult
    func alterTextSearchConfigurationOwner(name: String, newOwner: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER TEXT SEARCH CONFIGURATION \(qualifiedName) OWNER TO \(client.quoteIdentifier(newOwner))"
        return try await client.executeDDL(sql)
    }

    /// Move a text search configuration to a different schema.
    @discardableResult
    func alterTextSearchConfigurationSetSchema(name: String, newSchema: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER TEXT SEARCH CONFIGURATION \(qualifiedName) SET SCHEMA \(client.quoteIdentifier(newSchema))"
        return try await client.executeDDL(sql)
    }

    /// Drop a text search configuration.
    @discardableResult
    func dropTextSearchConfiguration(name: String, ifExists: Bool = false, cascade: Bool = false, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        var parts: [String] = ["DROP TEXT SEARCH CONFIGURATION"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(qualifiedName)
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    // MARK: - Text Search Dictionary

    /// Create a text search dictionary.
    @discardableResult
    func createTextSearchDictionary(
        name: String,
        template: String,
        options: [String: String]? = nil,
        schema: String? = nil
    ) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        var clauses: [String] = ["TEMPLATE = \(client.quoteIdentifier(template))"]
        if let options {
            for (key, value) in options {
                clauses.append("\(key) = \(client.quoteLiteral(value))")
            }
        }
        let sql = "CREATE TEXT SEARCH DICTIONARY \(qualifiedName) (\(clauses.joined(separator: ", ")))"
        return try await client.executeDDL(sql)
    }

    /// Drop a text search dictionary.
    @discardableResult
    func dropTextSearchDictionary(name: String, ifExists: Bool = false, cascade: Bool = false, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        var parts: [String] = ["DROP TEXT SEARCH DICTIONARY"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(qualifiedName)
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }
}
