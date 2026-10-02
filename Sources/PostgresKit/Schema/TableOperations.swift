
/// High-level Table Data Definition Language (DDL) operations.
public extension PostgresAdminClient {
    /// Create a new table.
    @discardableResult
    func createTable(
        name: String,
        schema: String? = nil,
        columns: [PostgresColumnDefinition],
        temporary: Bool = false,
        ifNotExists: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["CREATE"]
        if temporary { parts.append("TEMPORARY") }
        parts.append("TABLE")
        if ifNotExists { parts.append("IF NOT EXISTS") }
        parts.append(client.quoteQualified(name, schema: schema))

        let columnDefinitions = columns.map { column in
            var columnDef = "\(client.quoteIdentifier(column.name)) \(column.dataType)"
            if let defaultValue = column.defaultValue { columnDef += " DEFAULT \(defaultValue)" }
            if column.nullable == false { columnDef += " NOT NULL" }
            if column.primaryKey { columnDef += " PRIMARY KEY" }
            if column.unique { columnDef += " UNIQUE" }
            return columnDef
        }.joined(separator: ", ")

        parts.append("(\(columnDefinitions))")
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Drop an existing table.
    @discardableResult
    func dropTable(name: String, ifExists: Bool = false, cascade: Bool = false, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        var parts: [String] = ["DROP TABLE"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(qualifiedName)
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Add a column to an existing table.
    @discardableResult
    func addColumn(
        table: String,
        column: PostgresColumnDefinition,
        using: String? = nil
    ) async throws -> Int {
        var columnDef = "\(client.quoteIdentifier(column.name)) \(column.dataType)"
        if let defaultValue = column.defaultValue { columnDef += " DEFAULT \(defaultValue)" }
        if column.nullable == false { columnDef += " NOT NULL" }
        if column.primaryKey { columnDef += " PRIMARY KEY" }
        if column.unique { columnDef += " UNIQUE" }

        var parts: [String] = ["ALTER TABLE \(client.quoteIdentifier(table))", "ADD COLUMN \(columnDef)"]
        if let using { parts.append("USING \(using)") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Remove a column from a table.
    @discardableResult
    func dropColumn(table: String, column: String) async throws -> Int {
        let sql = "ALTER TABLE \(client.quoteIdentifier(table)) DROP COLUMN \(client.quoteIdentifier(column))"
        return try await client.executeDDL(sql)
    }

    /// Rename an existing table.
    @discardableResult
    func renameTable(oldName: String, newName: String, schema: String? = nil) async throws -> Int {
        let qualifiedOldName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(oldName))" } ?? client.quoteIdentifier(oldName)
        let sql = "ALTER TABLE \(qualifiedOldName) RENAME TO \(client.quoteIdentifier(newName))"
        return try await client.executeDDL(sql)
    }

    /// Rename a column within a table.
    @discardableResult
    func renameColumn(table: String, oldName: String, newName: String) async throws -> Int {
        let sql = "ALTER TABLE \(client.quoteIdentifier(table)) RENAME COLUMN \(client.quoteIdentifier(oldName)) TO \(client.quoteIdentifier(newName))"
        return try await client.executeDDL(sql)
    }

    /// Change a column's data type.
    @discardableResult
    func alterColumnType(table: String, column: String, newType: String, using: String? = nil) async throws -> Int {
        var parts: [String] = [
            "ALTER TABLE \(client.quoteIdentifier(table))",
            "ALTER COLUMN \(client.quoteIdentifier(column))",
            "TYPE \(newType)"
        ]
        if let using { parts.append("USING \(using)") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Set or remove a column's default value.
    @discardableResult
    func alterColumnDefault(table: String, column: String, defaultValue: String?) async throws -> Int {
        let sql: String
        if let defaultValue = defaultValue {
            sql = "ALTER TABLE \(client.quoteIdentifier(table)) ALTER COLUMN \(client.quoteIdentifier(column)) SET DEFAULT \(defaultValue)"
        } else {
            sql = "ALTER TABLE \(client.quoteIdentifier(table)) ALTER COLUMN \(client.quoteIdentifier(column)) DROP DEFAULT"
        }
        return try await client.executeDDL(sql)
    }

    /// Set or remove a column's NOT NULL constraint.
    @discardableResult
    func alterColumnNullability(table: String, column: String, nullable: Bool) async throws -> Int {
        let sql = "ALTER TABLE \(client.quoteIdentifier(table)) ALTER COLUMN \(client.quoteIdentifier(column)) \(nullable ? "DROP" : "SET") NOT NULL"
        return try await client.executeDDL(sql)
    }

    /// Copy data between tables.
    @discardableResult
    func copyTable(
        from sourceTable: String,
        to targetTable: String,
        columns: [String]? = nil
    ) async throws -> Int {
        let columnList = columns.map { "(\($0.map(client.quoteIdentifier).joined(separator: ", ")))" } ?? ""
        let sql = "INSERT INTO \(client.quoteIdentifier(targetTable))\(columnList) SELECT * FROM \(client.quoteIdentifier(sourceTable))"
        return try await client.executeDDL(sql)
    }

    /// Create a table from the results of a SELECT query.
    @discardableResult
    func createTableAs(
        name: String,
        selectQuery: String,
        temporary: Bool = false,
        ifNotExists: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["CREATE"]
        if temporary { parts.append("TEMPORARY") }
        parts.append("TABLE")
        if ifNotExists { parts.append("IF NOT EXISTS") }
        parts.append(client.quoteIdentifier(name))
        parts.append("AS \(selectQuery)")
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Set a column's statistics target.
    @discardableResult
    func alterColumnStatistics(table: String, column: String, target: Int, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let sql = "ALTER TABLE \(qualifiedTable) ALTER COLUMN \(client.quoteIdentifier(column)) SET STATISTICS \(target)"
        return try await client.executeDDL(sql)
    }

    /// Set a column's storage mode (PLAIN, MAIN, EXTERNAL, EXTENDED).
    @discardableResult
    func alterColumnStorage(table: String, column: String, storage: String, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let sql = "ALTER TABLE \(qualifiedTable) ALTER COLUMN \(client.quoteIdentifier(column)) SET STORAGE \(storage)"
        return try await client.executeDDL(sql)
    }

    /// Move table to a different schema.
    @discardableResult
    func alterTableSetSchema(table: String, schema: String, newSchema: String) async throws -> Int {
        let qualifiedTable = "\(client.quoteIdentifier(schema)).\(client.quoteIdentifier(table))"
        let sql = "ALTER TABLE \(qualifiedTable) SET SCHEMA \(client.quoteIdentifier(newSchema))"
        return try await client.executeDDL(sql)
    }

    /// Change table owner.
    @discardableResult
    func alterTableOwner(table: String, newOwner: String, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let sql = "ALTER TABLE \(qualifiedTable) OWNER TO \(client.quoteIdentifier(newOwner))"
        return try await client.executeDDL(sql)
    }

    /// Set table tablespace.
    @discardableResult
    func alterTableSetTablespace(table: String, tablespace: String, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let sql = "ALTER TABLE \(qualifiedTable) SET TABLESPACE \(client.quoteIdentifier(tablespace))"
        return try await client.executeDDL(sql)
    }

    /// Set table storage parameter (e.g. fillfactor, autovacuum settings).
    @discardableResult
    func alterTableSetParameter(table: String, parameter: String, value: String, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let sql = "ALTER TABLE \(qualifiedTable) SET (\(parameter) = \(value))"
        return try await client.executeDDL(sql)
    }

    /// Reset table storage parameter to default.
    @discardableResult
    func alterTableResetParameter(table: String, parameter: String, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let sql = "ALTER TABLE \(qualifiedTable) RESET (\(parameter))"
        return try await client.executeDDL(sql)
    }

    /// Enable or disable row-level security on a table.
    @discardableResult
    func alterTableRowLevelSecurity(table: String, enable: Bool, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let sql = "ALTER TABLE \(qualifiedTable) \(enable ? "ENABLE" : "DISABLE") ROW LEVEL SECURITY"
        return try await client.executeDDL(sql)
    }

    /// Force or no-force row-level security for table owner.
    @discardableResult
    func alterTableForceRowLevelSecurity(table: String, force: Bool, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let sql = "ALTER TABLE \(qualifiedTable) \(force ? "FORCE" : "NO FORCE") ROW LEVEL SECURITY"
        return try await client.executeDDL(sql)
    }

    /// Enable or disable a trigger on a table.
    @discardableResult
    func alterTableTrigger(table: String, trigger: String, enable: Bool, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let sql = "ALTER TABLE \(qualifiedTable) \(enable ? "ENABLE" : "DISABLE") TRIGGER \(client.quoteIdentifier(trigger))"
        return try await client.executeDDL(sql)
    }

    /// Cluster a table on a specific index, or re-cluster if index is nil.
    @discardableResult
    func clusterTable(table: String, index: String?, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let sql: String
        if let index {
            sql = "CLUSTER \(qualifiedTable) USING \(client.quoteIdentifier(index))"
        } else {
            sql = "CLUSTER \(qualifiedTable)"
        }
        return try await client.executeDDL(sql)
    }
}
