import Foundation

extension PostgresClient {
    /// `"schema"."name"`, or `"name"` when no schema is given (resolved through search_path).
    internal func quoteQualified(_ name: String, schema: String?) -> String {
        guard let schema else { return quoteIdentifier(name) }
        return "\(quoteIdentifier(schema)).\(quoteIdentifier(name))"
    }
}
