
/// Query plan analysis operations.
public extension PostgresExecutionPlanClient {
    /// Run EXPLAIN on a query and return the plan as an array of strings.
    func explain(
        _ query: String,
        analyze: Bool = false,
        verbose: Bool = false,
        buffers: Bool = false,
        format: ExplainFormat? = nil
    ) async throws -> [String] {
        var options: [String] = []
        if analyze { options.append("ANALYZE") }
        if verbose { options.append("VERBOSE") }
        if buffers { options.append("BUFFERS") }
        if let format { options.append("FORMAT \(format.rawValue)") }

        let sql: String
        if options.isEmpty {
            sql = "EXPLAIN \(query)"
        } else {
            sql = "EXPLAIN (\(options.joined(separator: ", "))) \(query)"
        }

        let rows = try await client.simpleQuery(sql)
        var result: [String] = []
        for try await line in rows.decode(String.self) {
            result.append(line)
        }
        return result
    }
}


/// Output format for EXPLAIN.
public enum ExplainFormat: String, Sendable {
    case text = "TEXT"
    case json = "JSON"
    case xml = "XML"
    case yaml = "YAML"
}
