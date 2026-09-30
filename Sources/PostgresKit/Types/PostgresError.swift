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

    /// The server's primary message exactly as sent (``message`` adds constraint, table and detail).
    public let serverMessage: String?

    /// Position inside an internally generated query (for example inside a PL/pgSQL function), if any.
    public let internalPosition: Int?

    /// Full server information (available through withDebugging()).
    internal let serverInfo: [String: String]?

    /// Original PSQLError (kept for compatibility).
    internal let originalError: PSQLError?

    /// Why a connection could not be made, when the driver knows more than ``message`` says (a
    /// missing Kerberos ticket, a wrong key password, a server that asks for a password).
    public let connectionProblem: PostgresConnectionProblem?

    internal init(
        message: String,
        sqlState: String? = nil,
        severity: String? = nil,
        serverInfo: [String: String]? = nil,
        originalError: PSQLError? = nil,
        connectionProblem: PostgresConnectionProblem? = nil
    ) {
        self.connectionProblem = connectionProblem ?? originalError.flatMap(PostgresConnectionProblem.init(psqlError:))
        self.message = message
        self.sqlState = sqlState
        self.severity = severity
        self.serverInfo = serverInfo
        self.originalError = originalError
        self.position = serverInfo?["position"].flatMap(Int.init)
        self.hint = serverInfo?["hint"]
        self.detail = serverInfo?["detail"]
        self.internalPosition = serverInfo?["internalPosition"].flatMap(Int.init)
        self.serverMessage = serverInfo?["message"]
    }

    /// Create from PSQLError with enhanced parsing.
    internal init(from psqLError: PSQLError) {
        self.originalError = psqLError
        self.connectionProblem = PostgresConnectionProblem(psqlError: psqLError)

        if let serverInfo = psqLError.serverInfo {
            self.sqlState = serverInfo[.sqlState]
            self.severity = serverInfo[.severity]
            self.position = serverInfo[.position].flatMap(Int.init)
            self.hint = serverInfo[.hint]
            self.detail = serverInfo[.detail]
            self.internalPosition = serverInfo[.internalPosition].flatMap(Int.init)
            self.serverMessage = serverInfo[.message]

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
                "message": serverInfo[.message],
            ].compactMapValues { $0 }
        } else {
            self.sqlState = nil
            self.severity = nil
            self.position = nil
            self.hint = nil
            self.detail = nil
            self.internalPosition = nil
            self.serverMessage = nil
            self.serverInfo = nil
            self.message = PostgresErrorParsing.extractMessage(from: psqLError)
        }
    }

    /// From PostgresNIO's older `PostgresError.server` (thrown by its future-based query API): the
    /// same fields as a `PSQLError`, so SQLSTATE, hint and position are kept.
    internal init(legacyServerError error: PostgresMessage.Error) {
        let fields = error.fields
        var message = fields[.message] ?? error.description
        if let constraint = fields[.constraintName] {
            message += " (constraint: \(constraint))"
        } else if let table = fields[.tableName] {
            message += " (table: \(table))"
        }
        if let detail = fields[.detail], !detail.isEmpty { message += " - \(detail)" }
        self.init(
            message: message,
            sqlState: fields[.sqlState],
            severity: fields[.severity] ?? fields[.localizedSeverity],
            serverInfo: [
                "detail": fields[.detail], "hint": fields[.hint], "position": fields[.position],
                "internalPosition": fields[.internalPosition], "message": fields[.message],
                "schemaName": fields[.schemaName], "tableName": fields[.tableName],
                "columnName": fields[.columnName], "constraintName": fields[.constraintName],
                "routine": fields[.routine],
            ].compactMapValues { $0 },
            originalError: nil
        )
    }

    /// Convert any error into a PostgresError.
    internal static func from(_ error: any Error) -> PostgresError {
        if let psqlError = error as? PSQLError { return PostgresError(from: psqlError) }
        if case .server(let message)? = error as? PostgresNIO.PostgresError { return PostgresError(legacyServerError: message) }
        if let postgresError = error as? PostgresError { return postgresError }
        if let ioError = error as? IOError { return PostgresError(message: PostgresErrorParsing.describeIOError(ioError)) }
        return PostgresError(message: error.localizedDescription, connectionProblem: PostgresConnectionProblem(error: error))
    }

    /// Like ``from(_:)`` for driver errors (`PSQLError`, `IOError`); any other error is returned unchanged.
    internal static func fromDriver(_ error: any Error) -> any Error {
        if let psqlError = error as? PSQLError { return PostgresError(from: psqlError) }
        if case .server(let message)? = error as? PostgresNIO.PostgresError { return PostgresError(legacyServerError: message) }
        if let ioError = error as? IOError { return PostgresError(message: PostgresErrorParsing.describeIOError(ioError)) }
        return error
    }

    internal static func protocolError(_ message: String) -> PostgresError { .init(message: message) }
    internal static func encodingError(message: String, type: Any.Type) -> PostgresError { .init(message: message) }
    internal static func encodingError(type: Any.Type) -> PostgresError { .init(message: "Could not encode value of type \(type) to PGData") }
    /// Object not found in the catalog.
    public static func objectNotFound(_ message: String) -> PostgresError { .init(message: message) }

    /// A copy with `hint` set (used when the driver can suggest a fix the server did not).
    internal func withHint(_ hint: String) -> PostgresError {
        var info = serverInfo ?? [:]
        info["hint"] = hint
        return PostgresError(message: message, sqlState: sqlState, severity: severity, serverInfo: info, originalError: originalError, connectionProblem: connectionProblem)
    }

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

extension PostgresError: PostgresServerErrorCode {
    /// The server's SQLSTATE, for PostgresWire's failover.
    public var serverSQLState: String? { sqlState }
}

/// What stopped a connection, for a client that offers the fix (a ticket viewer, the key password
/// field, the password field).
public enum PostgresConnectionProblem: Sendable {
    /// Kerberos sign-in failed; see the error's ``PostgresKerberosError/kind``.
    case kerberos(PostgresKerberosError)
    /// The client certificate or key could not be opened; see ``PostgresTLSFileError/kind``.
    case clientCertificate(PostgresTLSFileError)
    /// The server asks for a password and none was given (for example, it does not accept Kerberos).
    case passwordRequired

    init?(error: any Error) {
        switch error {
        case let kerberos as PostgresKerberosError: self = .kerberos(kerberos)
        case let file as PostgresTLSFileError: self = .clientCertificate(file)
        case let psql as PSQLError: self.init(psqlError: psql)
        default: return nil
        }
    }

    init?(psqlError: PSQLError) {
        if psqlError.code == .authMechanismRequiresPassword { self = .passwordRequired; return }
        guard let underlying = psqlError.underlying, !(underlying is PSQLError) else { return nil }
        self.init(error: underlying)
    }
}
