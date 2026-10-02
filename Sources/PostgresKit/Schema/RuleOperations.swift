
/// Rule DDL operations.
public extension PostgresAdminClient {

    /// Create a rule on a table.
    ///
    /// - Parameters:
    ///   - name: The rule name.
    ///   - table: The target table name.
    ///   - event: One of `SELECT`, `INSERT`, `UPDATE`, `DELETE`.
    ///   - doInstead: If `true`, uses `DO INSTEAD`; otherwise `DO ALSO`.
    ///   - condition: Optional `WHERE` condition for the rule.
    ///   - commands: The SQL commands the rule executes. Use `"NOTHING"` for a no-op rule.
    ///   - schema: Optional schema name.
    ///   - orReplace: If `true`, uses `CREATE OR REPLACE RULE`.
    @discardableResult
    func createRule(
        name: String,
        table: String,
        event: String,
        doInstead: Bool = false,
        condition: String? = nil,
        commands: String,
        schema: String? = nil,
        orReplace: Bool = false
    ) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        var parts: [String] = []
        if orReplace {
            parts.append("CREATE OR REPLACE RULE")
        } else {
            parts.append("CREATE RULE")
        }
        parts.append("\(client.quoteIdentifier(name)) AS")
        parts.append("ON \(event) TO \(qualifiedTable)")
        if let condition { parts.append("WHERE (\(condition))") }
        let doClause = doInstead ? "DO INSTEAD" : "DO ALSO"
        parts.append("\(doClause) \(commands)")
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Rename a rule on a table.
    @discardableResult
    func alterRuleRename(ruleName: String, tableName: String, newName: String, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(tableName))" } ?? client.quoteIdentifier(tableName)
        let sql = "ALTER RULE \(client.quoteIdentifier(ruleName)) ON \(qualifiedTable) RENAME TO \(client.quoteIdentifier(newName))"
        return try await client.executeDDL(sql)
    }

    /// Drop a rule from a table.
    @discardableResult
    func dropRule(name: String, table: String, ifExists: Bool = false, cascade: Bool = false, schema: String? = nil) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        var parts: [String] = ["DROP RULE"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append("\(client.quoteIdentifier(name)) ON \(qualifiedTable)")
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }
}
