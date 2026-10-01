import PostgresWire

/// High-level Database and Schema Data Definition Language (DDL) operations.
public extension PostgresAdminClient {
    /// Create a new database.
    @discardableResult
    func createDatabase(
        name: String,
        ifNotExists: Bool = false,
        owner: String? = nil,
        template: String? = nil,
        encoding: String? = nil,
        lcCollate: String? = nil,
        lcCtype: String? = nil,
        icuLocale: String? = nil,
        icuRules: String? = nil,
        localeProvider: String? = nil,
        collationVersion: String? = nil,
        tablespace: String? = nil,
        allowConnections: Bool? = nil,
        connectionLimit: Int? = nil,
        isTemplate: Bool? = nil,
        strategy: String? = nil
    ) async throws -> Int {
        // PostgreSQL has no CREATE DATABASE IF NOT EXISTS: look for it first.
        if ifNotExists, try await databaseExists(name) { return 0 }
        var parts: [String] = ["CREATE DATABASE"]
        parts.append(client.quoteIdentifier(name))

        var withClauses: [String] = []
        if let template { withClauses.append("TEMPLATE = \(client.quoteIdentifier(template))") }
        if let owner { withClauses.append("OWNER = \(client.quoteIdentifier(owner))") }
        if let encoding { withClauses.append("ENCODING = \(client.quoteLiteral(encoding))") }
        if let lcCollate { withClauses.append("LC_COLLATE = \(client.quoteLiteral(lcCollate))") }
        if let lcCtype { withClauses.append("LC_CTYPE = \(client.quoteLiteral(lcCtype))") }
        if let icuLocale { withClauses.append("ICU_LOCALE = \(client.quoteLiteral(icuLocale))") }
        if let icuRules { withClauses.append("ICU_RULES = \(client.quoteLiteral(icuRules))") }
        if let localeProvider { withClauses.append("LOCALE_PROVIDER = \(localeProvider)") }
        if let collationVersion { withClauses.append("COLLATION_VERSION = \(client.quoteLiteral(collationVersion))") }
        if let tablespace { withClauses.append("TABLESPACE = \(client.quoteIdentifier(tablespace))") }
        if let allowConnections { withClauses.append("ALLOW_CONNECTIONS = \(allowConnections)") }
        if let connectionLimit { withClauses.append("CONNECTION LIMIT = \(connectionLimit)") }
        if let isTemplate { withClauses.append("IS_TEMPLATE = \(isTemplate)") }
        if let strategy { withClauses.append("STRATEGY = \(strategy)") }

        if !withClauses.isEmpty {
            parts.append("WITH")
            parts.append(withClauses.joined(separator: " "))
        }

        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// True when a database (or template) with this name exists.
    func databaseExists(_ name: String) async throws -> Bool {
        let bind = try client.toPGData(value: name)
        return try await client.withConnection { conn in
            let rows = try await conn.query("SELECT count(*) FROM pg_catalog.pg_database WHERE datname = $1", binds: [bind])
            for try await count in rows.decode(Int64.self) { return count > 0 }
            return false
        }
    }

    /// Drop an existing database.
    @discardableResult
    func dropDatabase(name: String, ifExists: Bool = false, withForce: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP DATABASE"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        if withForce { parts.append("WITH (FORCE)") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Change the default search path to the specified database/schema.
    @discardableResult
    func useDatabase(_ name: String) async throws -> Int {
        return try await client.executeDDL("SET search_path TO \(client.quoteIdentifier(name))")
    }

    /// Create a new schema.
    @discardableResult
    func createSchema(name: String, ifNotExists: Bool = false, authorization: String? = nil) async throws -> Int {
        var parts: [String] = ["CREATE SCHEMA"]
        if ifNotExists { parts.append("IF NOT EXISTS") }
        parts.append(client.quoteIdentifier(name))
        if let authorization { parts.append("AUTHORIZATION \(client.quoteIdentifier(authorization))") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Drop an existing schema.
    @discardableResult
    func dropSchema(name: String, ifExists: Bool = false, cascade: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP SCHEMA"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Rename a schema.
    func alterSchemaRename(name: String, newName: String) async throws {
        let sql = "ALTER SCHEMA \(client.quoteIdentifier(name)) RENAME TO \(client.quoteIdentifier(newName))"
        _ = try await client.executeDDL(sql)
    }

    /// Change schema owner.
    func alterSchemaOwner(name: String, newOwner: String) async throws {
        let sql = "ALTER SCHEMA \(client.quoteIdentifier(name)) OWNER TO \(client.quoteIdentifier(newOwner))"
        _ = try await client.executeDDL(sql)
    }

    /// Change database owner.
    func alterDatabaseOwner(name: String, newOwner: String) async throws {
        let sql = "ALTER DATABASE \(client.quoteIdentifier(name)) OWNER TO \(client.quoteIdentifier(newOwner))"
        _ = try await client.executeDDL(sql)
    }

    /// Alter database connection limit.
    func alterDatabaseConnectionLimit(name: String, limit: Int) async throws {
        let sql = "ALTER DATABASE \(client.quoteIdentifier(name)) CONNECTION LIMIT \(limit)"
        _ = try await client.executeDDL(sql)
    }

    /// Alter database is_template flag.
    func alterDatabaseIsTemplate(name: String, isTemplate: Bool) async throws {
        let sql = "ALTER DATABASE \(client.quoteIdentifier(name)) IS_TEMPLATE \(isTemplate)"
        _ = try await client.executeDDL(sql)
    }

    /// Alter database allow_connections flag.
    func alterDatabaseAllowConnections(name: String, allow: Bool) async throws {
        let sql = "ALTER DATABASE \(client.quoteIdentifier(name)) ALLOW_CONNECTIONS \(allow)"
        _ = try await client.executeDDL(sql)
    }

    /// Alter database tablespace.
    func alterDatabaseTablespace(name: String, tablespace: String) async throws {
        let sql = "ALTER DATABASE \(client.quoteIdentifier(name)) SET TABLESPACE \(client.quoteIdentifier(tablespace))"
        _ = try await client.executeDDL(sql)
    }

    /// Set a database-level configuration parameter.
    func alterDatabaseSet(name: String, parameter: String, value: String) async throws {
        let sql = "ALTER DATABASE \(client.quoteIdentifier(name)) SET \(client.quoteIdentifier(parameter)) TO \(client.quoteLiteral(value))"
        _ = try await client.executeDDL(sql)
    }

    /// Reset a database-level configuration parameter.
    func alterDatabaseReset(name: String, parameter: String) async throws {
        let sql = "ALTER DATABASE \(client.quoteIdentifier(name)) RESET \(client.quoteIdentifier(parameter))"
        _ = try await client.executeDDL(sql)
    }

    /// Update the database comment/description.
    func addDatabaseComment(name: String, comment: String?) async throws {
        let sql: String
        if let comment {
            sql = "COMMENT ON DATABASE \(client.quoteIdentifier(name)) IS \(client.quoteLiteral(comment))"
        } else {
            sql = "COMMENT ON DATABASE \(client.quoteIdentifier(name)) IS NULL"
        }
        _ = try await client.executeDDL(sql)
    }
}
