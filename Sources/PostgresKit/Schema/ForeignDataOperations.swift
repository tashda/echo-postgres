
/// Foreign Data Wrapper, Foreign Server, User Mapping, and Foreign Table DDL operations.
public extension PostgresAdminClient {

    // MARK: - Foreign Data Wrapper

    /// Create a foreign data wrapper.
    @discardableResult
    func createForeignDataWrapper(
        name: String,
        handler: String? = nil,
        validator: String? = nil,
        options: [String: String]? = nil
    ) async throws -> Int {
        var parts: [String] = ["CREATE FOREIGN DATA WRAPPER \(client.quoteIdentifier(name))"]
        if let handler { parts.append("HANDLER \(client.quoteIdentifier(handler))") }
        if let validator { parts.append("VALIDATOR \(client.quoteIdentifier(validator))") }
        if let options, !options.isEmpty {
            let optionList = options.map { "\(client.quoteIdentifier($0.key)) \(client.quoteLiteral($0.value))" }.joined(separator: ", ")
            parts.append("OPTIONS (\(optionList))")
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Rename a foreign data wrapper.
    @discardableResult
    func alterForeignDataWrapperRename(name: String, newName: String) async throws -> Int {
        let sql = "ALTER FOREIGN DATA WRAPPER \(client.quoteIdentifier(name)) RENAME TO \(client.quoteIdentifier(newName))"
        return try await client.executeDDL(sql)
    }

    /// Change a foreign data wrapper's owner.
    @discardableResult
    func alterForeignDataWrapperOwner(name: String, newOwner: String) async throws -> Int {
        let sql = "ALTER FOREIGN DATA WRAPPER \(client.quoteIdentifier(name)) OWNER TO \(client.quoteIdentifier(newOwner))"
        return try await client.executeDDL(sql)
    }

    /// Drop a foreign data wrapper.
    @discardableResult
    func dropForeignDataWrapper(name: String, ifExists: Bool = false, cascade: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP FOREIGN DATA WRAPPER"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    // MARK: - Foreign Server

    /// Create a foreign server.
    @discardableResult
    func createForeignServer(
        name: String,
        type: String? = nil,
        version: String? = nil,
        fdwName: String,
        options: [String: String]? = nil
    ) async throws -> Int {
        var parts: [String] = ["CREATE SERVER \(client.quoteIdentifier(name))"]
        if let type { parts.append("TYPE \(client.quoteLiteral(type))") }
        if let version { parts.append("VERSION \(client.quoteLiteral(version))") }
        parts.append("FOREIGN DATA WRAPPER \(client.quoteIdentifier(fdwName))")
        if let options, !options.isEmpty {
            let optionList = options.map { "\(client.quoteIdentifier($0.key)) \(client.quoteLiteral($0.value))" }.joined(separator: ", ")
            parts.append("OPTIONS (\(optionList))")
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Alter foreign server options.
    @discardableResult
    func alterForeignServerOptions(name: String, options: [String: String]) async throws -> Int {
        let optionList = options.map { "SET \(client.quoteIdentifier($0.key)) \(client.quoteLiteral($0.value))" }.joined(separator: ", ")
        let sql = "ALTER SERVER \(client.quoteIdentifier(name)) OPTIONS (\(optionList))"
        return try await client.executeDDL(sql)
    }

    /// Rename a foreign server.
    @discardableResult
    func alterForeignServerRename(name: String, newName: String) async throws -> Int {
        let sql = "ALTER SERVER \(client.quoteIdentifier(name)) RENAME TO \(client.quoteIdentifier(newName))"
        return try await client.executeDDL(sql)
    }

    /// Change a foreign server's owner.
    @discardableResult
    func alterForeignServerOwner(name: String, newOwner: String) async throws -> Int {
        let sql = "ALTER SERVER \(client.quoteIdentifier(name)) OWNER TO \(client.quoteIdentifier(newOwner))"
        return try await client.executeDDL(sql)
    }

    /// Drop a foreign server.
    @discardableResult
    func dropForeignServer(name: String, ifExists: Bool = false, cascade: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP SERVER"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    // MARK: - User Mapping

    /// Create a user mapping for a foreign server.
    @discardableResult
    func createUserMapping(
        serverName: String,
        userName: String,
        options: [String: String]? = nil
    ) async throws -> Int {
        var parts: [String] = ["CREATE USER MAPPING FOR \(client.quoteIdentifier(userName))"]
        parts.append("SERVER \(client.quoteIdentifier(serverName))")
        if let options, !options.isEmpty {
            let optionList = options.map { "\(client.quoteIdentifier($0.key)) \(client.quoteLiteral($0.value))" }.joined(separator: ", ")
            parts.append("OPTIONS (\(optionList))")
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Drop a user mapping from a foreign server.
    @discardableResult
    func dropUserMapping(serverName: String, userName: String, ifExists: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP USER MAPPING"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append("FOR \(client.quoteIdentifier(userName))")
        parts.append("SERVER \(client.quoteIdentifier(serverName))")
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    // MARK: - Foreign Table

    /// Create a foreign table.
    @discardableResult
    func createForeignTable(
        name: String,
        schema: String? = nil,
        serverName: String,
        columns: [PostgresColumnDefinition],
        options: [String: String]? = nil
    ) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        var parts: [String] = ["CREATE FOREIGN TABLE \(qualifiedName)"]

        let columnDefinitions = columns.map { column in
            var columnDef = "\(client.quoteIdentifier(column.name)) \(column.dataType)"
            if column.nullable == false { columnDef += " NOT NULL" }
            if let defaultValue = column.defaultValue { columnDef += " DEFAULT \(defaultValue)" }
            return columnDef
        }.joined(separator: ", ")

        parts.append("(\(columnDefinitions))")
        parts.append("SERVER \(client.quoteIdentifier(serverName))")
        if let options, !options.isEmpty {
            let optionList = options.map { "\(client.quoteIdentifier($0.key)) \(client.quoteLiteral($0.value))" }.joined(separator: ", ")
            parts.append("OPTIONS (\(optionList))")
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Drop a foreign table.
    @discardableResult
    func dropForeignTable(name: String, schema: String? = nil, ifExists: Bool = false, cascade: Bool = false) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        var parts: [String] = ["DROP FOREIGN TABLE"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(qualifiedName)
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }
}
