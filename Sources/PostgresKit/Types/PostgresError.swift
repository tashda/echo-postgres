import Foundation
import PostgresNIO

/// Enhanced PostgreSQL error handling with user-friendly API.
public struct PostgresError: Error, CustomStringConvertible, Sendable {
    /// User-friendly error message.
    public let message: String

    /// SQL state code (optional for advanced users).
    public let sqlState: String?

    /// Severity level (optional for advanced users).
    public let severity: String?

    /// 1-based character position of the error in the statement text, when the server reports one.
    public let position: Int?

    /// The server's hint, if any (for example "No function matches the given name and argument types.").
    public let hint: String?

    /// The server's detail message, if any.
    public let detail: String?

    /// Position inside an internally generated query (for example inside a PL/pgSQL function), if any.
    public let internalPosition: Int?

    /// Full server information (available through withDebugging()).
    internal let serverInfo: [String: String]?

    /// Original PSQLError (kept for compatibility).
    internal let originalError: PSQLError?

    internal init(
        message: String,
        sqlState: String? = nil,
        severity: String? = nil,
        serverInfo: [String: String]? = nil,
        originalError: PSQLError? = nil
    ) {
        self.message = message
        self.sqlState = sqlState
        self.severity = severity
        self.serverInfo = serverInfo
        self.originalError = originalError
        self.position = serverInfo?["position"].flatMap(Int.init)
        self.hint = serverInfo?["hint"]
        self.detail = serverInfo?["detail"]
        self.internalPosition = serverInfo?["internalPosition"].flatMap(Int.init)
    }

    /// Create from PSQLError with enhanced parsing.
    internal init(from psqLError: PSQLError) {
        self.originalError = psqLError

        if let serverInfo = psqLError.serverInfo {
            self.sqlState = serverInfo[.sqlState]
            self.severity = serverInfo[.severity]
            self.position = serverInfo[.position].flatMap(Int.init)
            self.hint = serverInfo[.hint]
            self.detail = serverInfo[.detail]
            self.internalPosition = serverInfo[.internalPosition].flatMap(Int.init)

            var detailedMessage = serverInfo[.message] ?? psqLError.localizedDescription
            if let constraintName = serverInfo[.constraintName] {
                detailedMessage += " (constraint: \(constraintName))"
            }
            if serverInfo[.constraintName] == nil, let tableName = serverInfo[.tableName] {
                detailedMessage += " (table: \(tableName))"
            }
            if let detail = serverInfo[.detail], !detail.isEmpty {
                detailedMessage += " - \(detail)"
            }
            self.message = detailedMessage

            self.serverInfo = [
                "detail": serverInfo[.detail], "hint": serverInfo[.hint],
                "internalQuery": serverInfo[.internalQuery], "locationContext": serverInfo[.locationContext],
                "schemaName": serverInfo[.schemaName], "tableName": serverInfo[.tableName],
                "columnName": serverInfo[.columnName], "dataTypeName": serverInfo[.dataTypeName],
                "constraintName": serverInfo[.constraintName], "file": serverInfo[.file],
                "line": serverInfo[.line], "routine": serverInfo[.routine],
                "position": serverInfo[.position], "internalPosition": serverInfo[.internalPosition],
            ].compactMapValues { $0 }
        } else {
            self.sqlState = nil
            self.severity = nil
            self.position = nil
            self.hint = nil
            self.detail = nil
            self.internalPosition = nil
            self.serverInfo = nil
            self.message = PostgresErrorParsing.extractMessage(from: psqLError)
        }
    }

    /// Convert any error into a PostgresError.
    internal static func from(_ error: any Error) -> PostgresError {
        if let psqlError = error as? PSQLError { return PostgresError(from: psqlError) }
        if let postgresError = error as? PostgresError { return postgresError }
        if let ioError = error as? IOError { return PostgresError(message: PostgresErrorParsing.describeIOError(ioError)) }
        return PostgresError(message: error.localizedDescription)
    }

    /// Like ``from(_:)`` for driver errors (`PSQLError`, `IOError`); any other error is returned unchanged.
    internal static func fromDriver(_ error: any Error) -> any Error {
        if let psqlError = error as? PSQLError { return PostgresError(from: psqlError) }
        if let ioError = error as? IOError { return PostgresError(message: PostgresErrorParsing.describeIOError(ioError)) }
        return error
    }

    internal static func protocolError(_ message: String) -> PostgresError { .init(message: message) }
    internal static func encodingError(message: String, type: Any.Type) -> PostgresError { .init(message: message) }
    internal static func encodingError(type: Any.Type) -> PostgresError { .init(message: "Could not encode value of type \(type) to PGData") }
    /// Object not found in the catalog.
    public static func objectNotFound(_ message: String) -> PostgresError { .init(message: message) }

    /// Get detailed debugging information.
    public func withDebugging() -> PostgresErrorDebugInfo {
        PostgresErrorDebugInfo(message: message, sqlState: sqlState, severity: severity, serverInfo: serverInfo ?? [:], originalError: originalError)
    }

    /// Check if this is a specific type of SQL error.
    public func isSQLState(_ sqlState: String) -> Bool { self.sqlState == sqlState }

    /// Check if this is a constraint violation error.
    public var isConstraintViolation: Bool { sqlState?.hasPrefix("23") == true }

    /// Check if this is a foreign key / referential integrity violation error.
    /// PostgreSQL may report `23503` (`foreign_key_violation`) or `23001` (`restrict_violation`)
    /// for rejected FK deletes depending on server version and action.
    public var isForeignKeyViolation: Bool { sqlState == "23503" || sqlState == "23001" }

    /// Check if this is a unique constraint violation error.
    public var isUniqueViolation: Bool { sqlState == "23505" }

    /// Check if this is a data type mismatch error.
    public var isDataTypeMismatch: Bool { sqlState == "42804" }

    public var description: String { message }
}

extension PostgresError: LocalizedError {
    public var errorDescription: String? { message }
    public var failureReason: String? { message }
    public var recoverySuggestion: String? {
        if isForeignKeyViolation { return "Ensure the referenced key exists in the parent table" }
        if isUniqueViolation { return "Ensure the values are unique within the constraint" }
        if isConstraintViolation { return "Check that the data satisfies all constraint requirements" }
        return nil
    }
    public var helpAnchor: String? {
        sqlState.map { "https://www.postgresql.org/docs/current/errcodes-appendix.html#ERRCODES-\($0)" }
    }
}
