import Foundation
import PostgresNIO

/// Retroactive `LocalizedError` conformance for PostgresNIO's `PSQLError`.
///
/// Without this, `PSQLError.localizedDescription` returns the unhelpful
/// "PostgresNIO.PSQLError error 1". This extension extracts the actual
/// server error message so callers that only see `Error.localizedDescription`
/// still get a readable string.
extension PSQLError: LocalizedError {
    public var errorDescription: String? {
        if let serverInfo {
            var result = serverInfo[.message] ?? String(describing: self)
            if let detail = serverInfo[.detail], !detail.isEmpty {
                result += " — \(detail)"
            }
            if let hint = serverInfo[.hint], !hint.isEmpty {
                result += " (Hint: \(hint))"
            }
            return result
        }
        return PostgresErrorParsing.extractMessage(from: self)
    }
}
