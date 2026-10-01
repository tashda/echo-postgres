import Foundation
import PGLibpq
#if canImport(EchoTLS)
import EchoTLS
#endif

/// A PostgreSQL error: from the server (with SQLSTATE and its fields) or from connecting.
public struct PostgresError: Error, CustomStringConvertible, Sendable {
    /// What happened: the server's message plus constraint or table and detail, or a sentence about
    /// the connection (libpq's own text is in ``detail``).
    public let message: String
    public let sqlState: String?
    public let severity: String?
    /// 1-based character position of the error in the statement text, when the server reports one.
    public let position: Int?
    public let hint: String?
    public let detail: String?
    /// The server's primary message exactly as sent (``message`` adds constraint, table and detail).
    public let serverMessage: String?
    /// Position inside an internally generated query (for example inside a PL/pgSQL function).
    public let internalPosition: Int?
    /// Every field the server sent (`schemaName`, `tableName`, `columnName`, `constraintName`,
    /// `dataTypeName`, `internalQuery`, `locationContext`, `file`, `line`, `routine` …).
    internal let serverInfo: [String: String]?
    /// Why a connection could not be made, when more is known than ``message`` says.
    public let connectionProblem: PostgresConnectionProblem?
    /// The connection itself failed or broke (not a statement's error).
    public let isConnectionError: Bool

    internal init(
        message: String,
        sqlState: String? = nil,
        severity: String? = nil,
        serverInfo: [String: String]? = nil,
        connectionProblem: PostgresConnectionProblem? = nil,
        isConnectionError: Bool = false
    ) {
        self.message = message
        self.sqlState = sqlState
        self.severity = severity
        self.serverInfo = serverInfo
        self.connectionProblem = connectionProblem
        self.isConnectionError = isConnectionError
        self.position = serverInfo?["position"].flatMap(Int.init)
        self.hint = serverInfo?["hint"]
        self.detail = serverInfo?["detail"]
        self.internalPosition = serverInfo?["internalPosition"].flatMap(Int.init)
        self.serverMessage = serverInfo?["message"]
    }

    /// A statement's error from the server.
    init(server error: PGServerError) {
        var message = error.message
        if let constraint = error.constraint {
            message += " (constraint: \(constraint))"
        } else if let table = error.table {
            message += " (table: \(table))"
        }
        if let detail = error.detail, !detail.isEmpty { message += " - \(detail)" }
        self.init(
            message: message,
            sqlState: error.sqlState,
            severity: error.severity,
            serverInfo: [
                "message": error.message, "detail": error.detail, "hint": error.hint,
                "position": error.position.map(String.init), "internalPosition": error.internalPosition.map(String.init),
                "internalQuery": error.internalQuery, "locationContext": error.context,
                "schemaName": error.schema, "tableName": error.table, "columnName": error.column,
                "dataTypeName": error.dataType, "constraintName": error.constraint,
                "file": error.file, "line": error.line.map(String.init), "routine": error.routine,
            ].compactMapValues { $0 }
        )
    }

    /// Connecting failed or the connection broke: Echo's sentence, with libpq's text as the
    /// detail (decision D15).
    init(connection error: PGConnectionError) {
        let explained = PostgresConnectionMessages.explain(error)
        self.init(
            message: explained.sentence,
            serverInfo: error.message.isEmpty ? nil : ["detail": error.message],
            connectionProblem: explained.problem,
            isConnectionError: true
        )
    }

    /// Any error from the driver as a PostgresError (errors that are none of the driver's are
    /// described by their own text).
    internal static func from(_ error: any Error) -> PostgresError {
        switch error {
        case let error as PostgresError: return error
        case let error as PGServerError: return PostgresError(server: error)
        case let error as PGConnectionError: return PostgresError(connection: error)
        #if canImport(EchoTLS)
        case let error as ClientCertificateError:
            let file = PostgresTLSFileError(error)
            return PostgresError(message: file.message, connectionProblem: .clientCertificate(file), isConnectionError: true)
        #endif
        case let error as PostgresKerberosError:
            return PostgresError(message: error.message, serverInfo: ["detail": error.details], connectionProblem: .kerberos(error), isConnectionError: true)
        case let error as PostgresTLSFileError:
            return PostgresError(message: error.message, connectionProblem: .clientCertificate(error), isConnectionError: true)
        default: return PostgresError(message: error.localizedDescription)
        }
    }

    /// Like ``from(_:)`` for the driver's own errors; any other error is returned unchanged.
    internal static func fromDriver(_ error: any Error) -> any Error {
        switch error {
        case is PGServerError, is PGConnectionError, is PostgresKerberosError, is PostgresTLSFileError: return from(error)
        #if canImport(EchoTLS)
        case is ClientCertificateError: return from(error)
        #endif
        default: return error
        }
    }

    internal static func protocolError(_ message: String) -> PostgresError { .init(message: message) }
    internal static func encodingError(message: String, type: Any.Type) -> PostgresError { .init(message: message) }
    internal static func encodingError(type: Any.Type) -> PostgresError { .init(message: "Could not send a value of type \(type) to the server") }
    /// Object not found in the catalog.
    public static func objectNotFound(_ message: String) -> PostgresError { .init(message: message) }

    /// A copy with `hint` set (used when the driver can suggest a fix the server did not).
    internal func withHint(_ hint: String) -> PostgresError {
        var info = serverInfo ?? [:]
        info["hint"] = hint
        return PostgresError(message: message, sqlState: sqlState, severity: severity, serverInfo: info,
                             connectionProblem: connectionProblem, isConnectionError: isConnectionError)
    }

    /// Where the error happened inside server code (`PL/pgSQL function f() line 3 at RAISE`).
    public var context: String? { serverInfo?["locationContext"] }
    /// The query an error inside server code came from (with ``internalPosition``).
    public var internalQuery: String? { serverInfo?["internalQuery"] }
    public var schemaName: String? { serverInfo?["schemaName"] }
    public var tableName: String? { serverInfo?["tableName"] }
    public var columnName: String? { serverInfo?["columnName"] }
    public var dataTypeName: String? { serverInfo?["dataTypeName"] }
    public var constraintName: String? { serverInfo?["constraintName"] }
    /// The server function that raised the error (`ExecConstraints` …).
    public var routine: String? { serverInfo?["routine"] }

    /// Get detailed debugging information.
    public func withDebugging() -> PostgresErrorDebugInfo {
        PostgresErrorDebugInfo(message: message, sqlState: sqlState, severity: severity, serverInfo: serverInfo ?? [:])
    }

    public func isSQLState(_ sqlState: String) -> Bool { self.sqlState == sqlState }
    public var isConstraintViolation: Bool { sqlState?.hasPrefix("23") == true }
    /// `23503` (`foreign_key_violation`) or `23001` (`restrict_violation`), depending on version and action.
    public var isForeignKeyViolation: Bool { sqlState == "23503" || sqlState == "23001" }
    public var isUniqueViolation: Bool { sqlState == "23505" }
    public var isDataTypeMismatch: Bool { sqlState == "42804" }
    /// The statement was cancelled (by the user or `statement_timeout`).
    public var isCancelled: Bool { sqlState == "57014" }
    public var isSerializationFailure: Bool { sqlState == "40001" }
    public var isDeadlock: Bool { sqlState == "40P01" }
    /// The connection broke while in use (or the server is shutting down).
    public var isConnectionLost: Bool {
        isConnectionError || sqlState?.hasPrefix("08") == true || sqlState == "57P01" || sqlState == "57P02" || sqlState == "57P03"
    }

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

/// What stopped a connection, for a client that offers the fix (a ticket viewer, the key password
/// field, the password field).
public enum PostgresConnectionProblem: Sendable {
    /// Kerberos sign-in failed; see the error's ``PostgresKerberosError/kind``.
    case kerberos(PostgresKerberosError)
    /// The client certificate or key could not be opened; see ``PostgresTLSFileError/kind``.
    case clientCertificate(PostgresTLSFileError)
    /// The server asks for a password and none was given (for example, it does not accept Kerberos).
    case passwordRequired
}
