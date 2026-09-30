import PostgresWire

/// Server configuration management.
public extension PostgresServerConfigClient {
    /// Set a server configuration parameter.
    @discardableResult
    func set(_ parameter: String, value: String, local: Bool = false) async throws -> Int {
        let sql = "SET\(local ? " LOCAL" : "") \(client.quoteIdentifier(parameter)) TO \(PostgresQuoting.quoteLiteral(value))"
        return try await client.executeDDL(sql)
    }

    /// Reset a server configuration parameter to its default value.
    @discardableResult
    func resetConfiguration(parameter: String, local: Bool = false) async throws -> Int {
        let sql = "RESET\(local ? " LOCAL" : "") \(client.quoteIdentifier(parameter))"
        return try await client.executeDDL(sql)
    }

    /// Show the current value of a server configuration parameter.
    func show(_ parameter: String) async throws -> String? {
        let rows = try await client.simpleQuery("SHOW \(client.quoteIdentifier(parameter))")
        for try await value in rows.decode(String?.self) { return value }
        return nil
    }
}
