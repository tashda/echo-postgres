import PostgresWire

/// High-level Type Data Definition Language (DDL) operations.
public extension PostgresTypeClient {
    /// Create a new enum type.
    @discardableResult
    ///
    /// PostgreSQL has no `CREATE TYPE IF NOT EXISTS`; with `ifNotExists` an existing type of the
    /// same name is left alone and 0 is returned.
    func createEnum(name: String, schema: String? = nil, values: [String], ifNotExists: Bool = false) async throws -> Int {
        if ifNotExists, try await typeExists(name: name, schema: schema) { return 0 }
        var parts: [String] = ["CREATE TYPE"]
        parts.append(client.quoteQualified(name, schema: schema))
        parts.append("AS ENUM")
        let valueList = values.map(PostgresQuoting.quoteLiteral).joined(separator: ", ")
        parts.append("(\(valueList))")
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Drop an existing enum type.
    @discardableResult
    func dropEnum(name: String, ifExists: Bool = false, cascade: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP TYPE"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Add a value to an existing enum type.
    @discardableResult
    func addEnumValue(type: String, value: String, before: String? = nil, after: String? = nil) async throws -> Int {
        var parts: [String] = ["ALTER TYPE"]
        parts.append(client.quoteIdentifier(type))
        parts.append("ADD VALUE \(PostgresQuoting.quoteLiteral(value))")
        if let before {
            parts.append("BEFORE \(PostgresQuoting.quoteLiteral(before))")
        } else if let after {
            parts.append("AFTER \(PostgresQuoting.quoteLiteral(after))")
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Rename an existing value in an enum type.
    @discardableResult
    func renameEnumValue(type: String, oldValue: String, newValue: String) async throws -> Int {
        let sql = "ALTER TYPE \(client.quoteIdentifier(type)) RENAME VALUE \(PostgresQuoting.quoteLiteral(oldValue)) TO \(PostgresQuoting.quoteLiteral(newValue))"
        return try await client.executeDDL(sql)
    }
}
