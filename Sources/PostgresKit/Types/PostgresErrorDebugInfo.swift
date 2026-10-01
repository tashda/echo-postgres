/// Detailed debugging information for PostgreSQL errors.
public struct PostgresErrorDebugInfo: CustomStringConvertible, Sendable {
    public let message: String
    public let sqlState: String?
    public let severity: String?
    public let serverInfo: [String: String]

    /// Constraint name associated with the error, if available.
    public var constraintName: String? { serverInfo["constraintName"] }

    /// Table name associated with the error, if available.
    public var tableName: String? { serverInfo["tableName"] }

    /// Schema name associated with the error, if available.
    public var schemaName: String? { serverInfo["schemaName"] }

    /// Detailed error information from the server, if available.
    public var detail: String? { serverInfo["detail"] }

    /// A hint from the server on how to fix the error, if available.
    public var hint: String? { serverInfo["hint"] }

    public var description: String {
        var result = "PostgresErrorDebugInfo:\n"
        result += "  Message: \(message)\n"
        if let sqlState { result += "  SQL State: \(sqlState)\n" }
        if let severity { result += "  Severity: \(severity)\n" }
        if let constraintName { result += "  Constraint: \(constraintName)\n" }
        if let tableName { result += "  Table: \(tableName)\n" }
        if let schemaName { result += "  Schema: \(schemaName)\n" }
        if let detail { result += "  Detail: \(detail)\n" }
        if let hint { result += "  Hint: \(hint)\n" }
        if !serverInfo.isEmpty { result += "  Server Info: \(serverInfo)\n" }
        return result
    }
}
