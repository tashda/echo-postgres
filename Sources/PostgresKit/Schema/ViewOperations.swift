
/// High-level View Data Definition Language (DDL) operations.
public extension PostgresViewClient {
    /// Create a standard view.
    @discardableResult
    func createView(
        name: String,
        schema: String? = nil,
        query: String,
        temporary: Bool = false,
        orReplace: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["CREATE"]
        if orReplace { parts.append("OR REPLACE") }
        if temporary { parts.append("TEMPORARY") }
        parts.append("VIEW")
        parts.append(client.quoteQualified(name, schema: schema))
        parts.append("AS \(query)")
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Drop an existing view.
    @discardableResult
    func dropView(name: String, ifExists: Bool = false, cascade: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP VIEW"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Create a materialized view.
    @discardableResult
    func createMaterializedView(
        name: String,
        schema: String? = nil,
        query: String,
        ifNotExists: Bool = false,
        withData: Bool = true
    ) async throws -> Int {
        var parts: [String] = ["CREATE MATERIALIZED VIEW"]
        if ifNotExists { parts.append("IF NOT EXISTS") }
        parts.append(client.quoteQualified(name, schema: schema))
        parts.append("AS \(query)")
        // WITH NO DATA leaves the view unpopulated: reading it errors until it is refreshed.
        if !withData { parts.append("WITH NO DATA") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Refresh a materialized view's contents.
    @discardableResult
    func refreshMaterializedView(name: String, concurrently: Bool = false) async throws -> Int {
        var parts: [String] = ["REFRESH MATERIALIZED VIEW"]
        if concurrently { parts.append("CONCURRENTLY") }
        parts.append(client.quoteIdentifier(name))
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Drop an existing materialized view.
    @discardableResult
    func dropMaterializedView(name: String, ifExists: Bool = false, cascade: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP MATERIALIZED VIEW"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    // MARK: - ALTER VIEW

    /// Rename a view.
    @discardableResult
    func alterViewRename(name: String, newName: String, schema: String? = nil) async throws -> Int {
        let qualified = qualifiedName(name, schema: schema)
        return try await client.executeDDL(
            "ALTER VIEW \(qualified) RENAME TO \(client.quoteIdentifier(newName))"
        )
    }

    /// Move a view to a different schema.
    @discardableResult
    func alterViewSetSchema(name: String, newSchema: String, schema: String? = nil) async throws -> Int {
        let qualified = qualifiedName(name, schema: schema)
        return try await client.executeDDL(
            "ALTER VIEW \(qualified) SET SCHEMA \(client.quoteIdentifier(newSchema))"
        )
    }

    /// Change the owner of a view.
    @discardableResult
    func alterViewOwner(name: String, newOwner: String, schema: String? = nil) async throws -> Int {
        let qualified = qualifiedName(name, schema: schema)
        return try await client.executeDDL(
            "ALTER VIEW \(qualified) OWNER TO \(client.quoteIdentifier(newOwner))"
        )
    }

    /// Set a default value for a view column.
    @discardableResult
    func alterViewColumnDefault(
        name: String,
        column: String,
        defaultExpression: String,
        schema: String? = nil
    ) async throws -> Int {
        let qualified = qualifiedName(name, schema: schema)
        return try await client.executeDDL(
            "ALTER VIEW \(qualified) ALTER COLUMN \(client.quoteIdentifier(column)) SET DEFAULT \(defaultExpression)"
        )
    }

    /// Drop the default value for a view column.
    @discardableResult
    func alterViewDropColumnDefault(
        name: String,
        column: String,
        schema: String? = nil
    ) async throws -> Int {
        let qualified = qualifiedName(name, schema: schema)
        return try await client.executeDDL(
            "ALTER VIEW \(qualified) ALTER COLUMN \(client.quoteIdentifier(column)) DROP DEFAULT"
        )
    }

    // MARK: - ALTER MATERIALIZED VIEW

    /// Rename a materialized view.
    @discardableResult
    func alterMaterializedViewRename(name: String, newName: String, schema: String? = nil) async throws -> Int {
        let qualified = qualifiedName(name, schema: schema)
        return try await client.executeDDL(
            "ALTER MATERIALIZED VIEW \(qualified) RENAME TO \(client.quoteIdentifier(newName))"
        )
    }

    /// Move a materialized view to a different schema.
    @discardableResult
    func alterMaterializedViewSetSchema(name: String, newSchema: String, schema: String? = nil) async throws -> Int {
        let qualified = qualifiedName(name, schema: schema)
        return try await client.executeDDL(
            "ALTER MATERIALIZED VIEW \(qualified) SET SCHEMA \(client.quoteIdentifier(newSchema))"
        )
    }

    /// Change the owner of a materialized view.
    @discardableResult
    func alterMaterializedViewOwner(name: String, newOwner: String, schema: String? = nil) async throws -> Int {
        let qualified = qualifiedName(name, schema: schema)
        return try await client.executeDDL(
            "ALTER MATERIALIZED VIEW \(qualified) OWNER TO \(client.quoteIdentifier(newOwner))"
        )
    }

    // MARK: - Helpers

    private func qualifiedName(_ name: String, schema: String?) -> String {
        if let schema {
            return "\(client.quoteIdentifier(schema)).\(client.quoteIdentifier(name))"
        }
        return client.quoteIdentifier(name)
    }
}
