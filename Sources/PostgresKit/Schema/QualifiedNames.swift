import Foundation

extension PostgresClient {
    /// `"schema"."name"`, or `"name"` when no schema is given (resolved through search_path).
    internal func quoteQualified(_ name: String, schema: String?) -> String {
        guard let schema else { return quoteIdentifier(name) }
        return "\(quoteIdentifier(schema)).\(quoteIdentifier(name))"
    }

    /// A role in GRANT/REVOKE/policy lists. PUBLIC, CURRENT_USER, CURRENT_ROLE and SESSION_USER are
    /// keywords; quoting them would name a role that does not exist.
    internal func quoteGrantee(_ grantee: String) -> String {
        let keywords: Set<String> = ["PUBLIC", "CURRENT_USER", "CURRENT_ROLE", "SESSION_USER"]
        return keywords.contains(grantee.uppercased()) ? grantee.uppercased() : quoteIdentifier(grantee)
    }
}
