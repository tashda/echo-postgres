import PostgresWire

/// High-level Constraint Data Definition Language (DDL) operations.
public extension PostgresConstraintClient {
    /// Add a primary key constraint to a table.
    @discardableResult
    func addPrimaryKey(table: String, schema: String? = nil, column: String, constraintName: String? = nil) async throws -> Int {
        let name = constraintName ?? "pk_\(table)_\(column)"
        let sql = "ALTER TABLE \(client.quoteQualified(table, schema: schema)) ADD CONSTRAINT \(client.quoteIdentifier(name)) PRIMARY KEY (\(client.quoteIdentifier(column)))"
        return try await client.executeDDL(sql)
    }

    /// Add a foreign key constraint to a table.
    @discardableResult
    func addForeignKey(
        table: String,
        schema: String? = nil,
        column: String,
        referencesTable: String,
        referencesSchema: String? = nil,
        referencesColumn: String,
        constraintName: String? = nil,
        onDelete: PostgresForeignKeyAction? = nil,
        onUpdate: PostgresForeignKeyAction? = nil
    ) async throws -> Int {
        let name = constraintName ?? "fk_\(table)_\(column)_\(referencesTable)_\(referencesColumn)"
        var parts: [String] = [
            "ALTER TABLE \(client.quoteQualified(table, schema: schema))",
            "ADD CONSTRAINT \(client.quoteIdentifier(name))",
            "FOREIGN KEY (\(client.quoteIdentifier(column)))",
            "REFERENCES \(client.quoteQualified(referencesTable, schema: referencesSchema ?? schema))(\(client.quoteIdentifier(referencesColumn)))"
        ]
        if let onDelete { parts.append("ON DELETE \(onDelete.rawValue)") }
        if let onUpdate { parts.append("ON UPDATE \(onUpdate.rawValue)") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Add a unique constraint to a table.
    @discardableResult
    func addUniqueConstraint(table: String, schema: String? = nil, columns: [String], constraintName: String? = nil) async throws -> Int {
        let name = constraintName ?? "uq_\(table)_\(columns.joined(separator: "_"))"
        let columnList = columns.map { client.quoteIdentifier($0) }.joined(separator: ", ")
        let sql = "ALTER TABLE \(client.quoteQualified(table, schema: schema)) ADD CONSTRAINT \(client.quoteIdentifier(name)) UNIQUE (\(columnList))"
        return try await client.executeDDL(sql)
    }

    /// Add a check constraint to a table.
    @discardableResult
    func addCheckConstraint(table: String, schema: String? = nil, condition: String, constraintName: String) async throws -> Int {
        let sql = "ALTER TABLE \(client.quoteQualified(table, schema: schema)) ADD CONSTRAINT \(client.quoteIdentifier(constraintName)) CHECK (\(condition))"
        return try await client.executeDDL(sql)
    }

    /// Drop a constraint from a table.
    @discardableResult
    func dropConstraint(table: String, constraintName: String, cascade: Bool = false) async throws -> Int {
        var parts: [String] = [
            "ALTER TABLE \(client.quoteIdentifier(table))",
            "DROP CONSTRAINT \(client.quoteIdentifier(constraintName))"
        ]
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Add a primary key constraint with multiple columns.
    @discardableResult
    func addCompositePrimaryKey(table: String, columns: [String], constraintName: String? = nil, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let name = constraintName ?? "pk_\(table)_\(columns.joined(separator: "_"))"
        let columnList = columns.map { client.quoteIdentifier($0) }.joined(separator: ", ")
        let sql = "ALTER TABLE \(qualifiedTable) ADD CONSTRAINT \(client.quoteIdentifier(name)) PRIMARY KEY (\(columnList))"
        return try await client.executeDDL(sql)
    }

    /// Add a foreign key constraint with multiple columns.
    @discardableResult
    func addCompositeForeignKey(
        table: String, columns: [String],
        referencesTable: String, referencesColumns: [String],
        constraintName: String? = nil, schema: String? = nil,
        onDelete: PostgresForeignKeyAction? = nil,
        onUpdate: PostgresForeignKeyAction? = nil,
        deferrable: Bool = false,
        initiallyDeferred: Bool = false
    ) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let name = constraintName ?? "fk_\(table)_\(columns.joined(separator: "_"))_\(referencesTable)"
        let columnList = columns.map { client.quoteIdentifier($0) }.joined(separator: ", ")
        let refColumnList = referencesColumns.map { client.quoteIdentifier($0) }.joined(separator: ", ")
        let qualifiedRefTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(referencesTable))" } ?? client.quoteIdentifier(referencesTable)
        var parts: [String] = [
            "ALTER TABLE \(qualifiedTable)",
            "ADD CONSTRAINT \(client.quoteIdentifier(name))",
            "FOREIGN KEY (\(columnList))",
            "REFERENCES \(qualifiedRefTable)(\(refColumnList))"
        ]
        if let onDelete { parts.append("ON DELETE \(onDelete.rawValue)") }
        if let onUpdate { parts.append("ON UPDATE \(onUpdate.rawValue)") }
        if deferrable {
            parts.append("DEFERRABLE")
            if initiallyDeferred { parts.append("INITIALLY DEFERRED") }
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Add a check constraint with NOT VALID option.
    @discardableResult
    func addCheckConstraintNotValid(table: String, condition: String, constraintName: String, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let sql = "ALTER TABLE \(qualifiedTable) ADD CONSTRAINT \(client.quoteIdentifier(constraintName)) CHECK (\(condition)) NOT VALID"
        return try await client.executeDDL(sql)
    }

    /// Validate a previously NOT VALID constraint.
    @discardableResult
    func validateConstraint(table: String, constraintName: String, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let sql = "ALTER TABLE \(qualifiedTable) VALIDATE CONSTRAINT \(client.quoteIdentifier(constraintName))"
        return try await client.executeDDL(sql)
    }

    /// Add an exclusion constraint.
    @discardableResult
    func addExclusionConstraint(
        table: String,
        using: String,
        elements: [(column: String, operator: String)],
        constraintName: String? = nil,
        schema: String? = nil,
        whereClause: String? = nil
    ) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let name = constraintName ?? "excl_\(table)"
        let elementList = elements.map { "\(client.quoteIdentifier($0.column)) WITH \($0.operator)" }.joined(separator: ", ")
        var parts: [String] = [
            "ALTER TABLE \(qualifiedTable)",
            "ADD CONSTRAINT \(client.quoteIdentifier(name))",
            "EXCLUDE USING \(using) (\(elementList))"
        ]
        if let whereClause { parts.append("WHERE (\(whereClause))") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Rename a constraint.
    @discardableResult
    func renameConstraint(table: String, oldName: String, newName: String, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let sql = "ALTER TABLE \(qualifiedTable) RENAME CONSTRAINT \(client.quoteIdentifier(oldName)) TO \(client.quoteIdentifier(newName))"
        return try await client.executeDDL(sql)
    }
}
