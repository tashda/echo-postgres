
/// Event trigger DDL operations.
public extension PostgresTriggerClient {

    /// Create an event trigger.
    ///
    /// - Parameters:
    ///   - name: The trigger name.
    ///   - event: One of `ddl_command_start`, `ddl_command_end`, `table_rewrite`, `sql_drop`.
    ///   - function: The function to execute (must return `event_trigger`).
    ///   - tags: Optional list of command tags to filter on (e.g. `["CREATE TABLE", "DROP TABLE"]`).
    @discardableResult
    func createEventTrigger(
        name: String,
        event: String,
        function: String,
        tags: [String]? = nil
    ) async throws -> Int {
        var parts: [String] = ["CREATE EVENT TRIGGER \(client.quoteIdentifier(name))"]
        parts.append("ON \(event)")
        if let tags, !tags.isEmpty {
            let tagList = tags.map { client.quoteLiteral($0) }.joined(separator: ", ")
            parts.append("WHEN TAG IN (\(tagList))")
        }
        parts.append("EXECUTE FUNCTION \(function)()")
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Enable or disable an event trigger.
    @discardableResult
    func alterEventTriggerEnable(name: String, enable: Bool) async throws -> Int {
        let action = enable ? "ENABLE" : "DISABLE"
        let sql = "ALTER EVENT TRIGGER \(client.quoteIdentifier(name)) \(action)"
        return try await client.executeDDL(sql)
    }

    /// Rename an event trigger.
    @discardableResult
    func alterEventTriggerRename(name: String, newName: String) async throws -> Int {
        let sql = "ALTER EVENT TRIGGER \(client.quoteIdentifier(name)) RENAME TO \(client.quoteIdentifier(newName))"
        return try await client.executeDDL(sql)
    }

    /// Change an event trigger's owner.
    @discardableResult
    func alterEventTriggerOwner(name: String, newOwner: String) async throws -> Int {
        let sql = "ALTER EVENT TRIGGER \(client.quoteIdentifier(name)) OWNER TO \(client.quoteIdentifier(newOwner))"
        return try await client.executeDDL(sql)
    }

    /// Drop an event trigger.
    @discardableResult
    func dropEventTrigger(name: String, ifExists: Bool = false, cascade: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP EVENT TRIGGER"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }
}
