
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

    /// Create an index with advanced configuration. `storageParameters` become `WITH (…)`
    /// (`fillfactor`, `fastupdate`, `pages_per_range`, and an access method's own such as `m`,
    /// `ef_construction` or `lists`); `nullsDistinct: false` is `NULLS NOT DISTINCT` (PostgreSQL 15+).
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
        concurrently: Bool = false,
        storageParameters: [String: String] = [:]
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
            if let collation = column.collation { colDef += " COLLATE " + Self.qualifiedName(collation, client: client) }
            if let operatorClass = column.operatorClass {
                colDef += " " + operatorClass
                if !column.operatorClassParameters.isEmpty { colDef += "(\(Self.parameterList(column.operatorClassParameters, client: client)))" }
            }
            if let order = column.order { colDef += " " + order.rawValue }
            if let nullsOrder = column.nullsOrder { colDef += " NULLS " + nullsOrder.rawValue }
            return colDef
        }.joined(separator: ", ")
        parts.append("(\(columnList))")
        // PostgreSQL's order: INCLUDE, NULLS [NOT] DISTINCT, WITH, TABLESPACE, WHERE.
        if !include.isEmpty { parts.append("INCLUDE (\(include.map(client.quoteIdentifier).joined(separator: ", ")))") }
        if !nullsDistinct { parts.append("NULLS NOT DISTINCT") }
        if !storageParameters.isEmpty { parts.append("WITH (\(Self.parameterList(storageParameters, client: client)))") }
        if let tablespace { parts.append("TABLESPACE \(client.quoteIdentifier(tablespace))") }
        if let whereClause { parts.append("WHERE \(whereClause)") }

        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// `name = value, …` in key order: names that aren't plain identifiers are quoted, values that
    /// aren't numbers or words become literals.
    internal static func parameterList(_ parameters: [String: String], client: PostgresClient) -> String {
        parameters.keys.sorted().map { key in
            let name = key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil ? key : client.quoteIdentifier(key)
            let value = parameters[key] ?? ""
            let plain = value.range(of: "^(-?[0-9]+(\\.[0-9]+)?|[A-Za-z_][A-Za-z0-9_]*)$", options: .regularExpression) != nil
            return "\(name) = \(plain ? value : PostgresQuoting.quoteLiteral(value))"
        }.joined(separator: ", ")
    }

    /// `"C"`, or `"pg_catalog"."C"` for a qualified collation.
    internal static func qualifiedName(_ name: String, client: PostgresClient) -> String {
        name.split(separator: ".", maxSplits: 1).map { client.quoteIdentifier(String($0)) }.joined(separator: ".")
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
