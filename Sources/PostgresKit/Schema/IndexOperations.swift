import PostgresWire

/// High-level Index Data Definition Language (DDL) operations.
public extension PostgresIndexClient {
    /// Create a standard index.
    @discardableResult
    func createIndex(
        name: String,
        table: String,
        schema: String? = nil,
        columns: [String],
        unique: Bool = false,
        ifNotExists: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["CREATE"]
        if unique { parts.append("UNIQUE") }
        parts.append("INDEX")
        if ifNotExists { parts.append("IF NOT EXISTS") }
        parts.append(client.quoteIdentifier(name))
        parts.append("ON \(client.quoteQualified(table, schema: schema))")

        let columnList = columns.map { client.quoteIdentifier($0) }.joined(separator: ", ")
        parts.append("(\(columnList))")

        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Drop an existing index.
    @discardableResult
    func dropIndex(schema: String? = nil, name: String, ifExists: Bool = false, cascade: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP INDEX"]
        if ifExists { parts.append("IF EXISTS") }
        if let schema {
            parts.append("\(client.quoteIdentifier(schema)).\(client.quoteIdentifier(name))")
        } else {
            parts.append(client.quoteIdentifier(name))
        }
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Create an index with advanced configuration.
    @discardableResult
    func createAdvancedIndex(
        name: String,
        table: String,
        schema: String? = nil,
        columns: [PostgresIndexColumn],
        indexType: PostgresIndexType = .btree,
        unique: Bool = false,
        ifNotExists: Bool = false,
        include: [String] = [],
        whereClause: String? = nil,
        tablespace: String? = nil,
        nullsDistinct: Bool = true,
        concurrently: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["CREATE"]
        if unique { parts.append("UNIQUE") }
        parts.append("INDEX")
        // Without blocking writes; not inside a transaction. A failure leaves the index invalid.
        if concurrently { parts.append("CONCURRENTLY") }
        if ifNotExists { parts.append("IF NOT EXISTS") }
        parts.append(client.quoteIdentifier(name))
        parts.append("ON \(client.quoteQualified(table, schema: schema))")

        parts.append("USING \(indexType)")

        let columnList = columns.map { column in
            var colDef = column.isExpression ? "(\(column.name))" : client.quoteIdentifier(column.name)
            if let operatorClass = column.operatorClass { colDef += " " + operatorClass }
            if let order = column.order { colDef += " " + order.rawValue }
            if let nullsOrder = column.nullsOrder { colDef += " NULLS " + nullsOrder.rawValue }
            return colDef
        }.joined(separator: ", ")
        parts.append("(\(columnList))")
        if !include.isEmpty { parts.append("INCLUDE (\(include.map(client.quoteIdentifier).joined(separator: ", ")))") }

        if let whereClause { parts.append("WHERE \(whereClause)") }
        if let tablespace { parts.append("TABLESPACE \(client.quoteIdentifier(tablespace))") }
        if !nullsDistinct { parts.append("NULLS NOT DISTINCT") }

        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Rename an index.
    @discardableResult
    func renameIndex(name: String, newName: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER INDEX \(qualifiedName) RENAME TO \(client.quoteIdentifier(newName))"
        return try await client.executeDDL(sql)
    }

    /// Set index tablespace.
    @discardableResult
    func alterIndexSetTablespace(name: String, tablespace: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER INDEX \(qualifiedName) SET TABLESPACE \(client.quoteIdentifier(tablespace))"
        return try await client.executeDDL(sql)
    }
}
