
/// High-level Trigger Data Definition Language (DDL) operations.
public extension PostgresTriggerClient {
    /// Create a new trigger on a table.
    @discardableResult
    func createTrigger(
        name: String,
        table: String,
        schema: String? = nil,
        event: PostgresTriggerEvent,
        operations: [PostgresTriggerOperation],
        procedure: String,
        orReplace: Bool = false,
        constraint: Bool = false,
        forEach: PostgresTriggerForEach = .row,
        when: String? = nil
    ) async throws -> Int {
        var parts: [String] = ["CREATE"]
        if orReplace { parts.append("OR REPLACE") }
        parts.append("TRIGGER")
        if constraint { parts.append("CONSTRAINT") }
        parts.append(client.quoteIdentifier(name))
        parts.append(event.rawValue)

        let operationList = operations.map { $0.rawValue }.joined(separator: " OR ")
        parts.append(operationList)
        parts.append("ON \(client.quoteQualified(table, schema: schema))")

        if let when { parts.append("WHEN (\(when))") }
        parts.append("FOR EACH \(forEach.rawValue)")
        parts.append("EXECUTE FUNCTION \(procedure)")

        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Drop an existing trigger from a table.
    @discardableResult
    func dropTrigger(name: String, table: String, ifExists: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP TRIGGER"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        parts.append("ON \(client.quoteIdentifier(table))")
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Enable or disable a trigger on a table.
    @discardableResult
    func alterTrigger(name: String, table: String, enabled: Bool) async throws -> Int {
        let sql = "ALTER TABLE \(client.quoteIdentifier(table)) \(enabled ? "ENABLE" : "DISABLE") TRIGGER \(client.quoteIdentifier(name))"
        return try await client.executeDDL(sql)
    }
}
