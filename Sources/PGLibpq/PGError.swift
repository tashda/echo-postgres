#if canImport(CLibpq)
internal import CLibpq
#else
internal import CLibpqSystem
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
/// The fields of a server error or notice (every `PG_DIAG_*` libpq reports).
public struct PGServerError: Error, Sendable, Equatable {
    public var severity: String?
    public var sqlState: String?
    public var message: String
    public var detail: String?
    public var hint: String?
    public var position: Int?
    public var internalPosition: Int?
    public var internalQuery: String?
    public var context: String?
    public var schema: String?
    public var table: String?
    public var column: String?
    public var dataType: String?
    public var constraint: String?
    public var file: String?
    public var line: Int?
    public var routine: String?

    init(result: OpaquePointer) {
        // The PG_DIAG_* codes of postgres_ext.h (character macros, which Swift doesn't import).
        func field(_ code: Unicode.Scalar) -> String? {
            guard let value = PQresultErrorField(result, Int32(code.value)) else { return nil }
            return String(cString: value)
        }
        let primary = field("M")
        severity = field("V") ?? field("S")
        sqlState = field("C")
        message = primary ?? Self.trimmed(String(cString: PQresultErrorMessage(result)))
        detail = field("D")
        hint = field("H")
        position = field("P").flatMap { Int($0) }
        internalPosition = field("p").flatMap { Int($0) }
        internalQuery = field("q")
        context = field("W")
        schema = field("s")
        table = field("t")
        column = field("c")
        dataType = field("d")
        constraint = field("n")
        file = field("F")
        line = field("L").flatMap { Int($0) }
        routine = field("R")
    }

    static func trimmed(_ text: String) -> String {
        var text = Substring(text)
        while let last = text.last, last.isWhitespace { text = text.dropLast() }
        return String(text)
    }
}

/// A failure of the connection itself (not a statement's error, which is `PGServerError`).
public struct PGConnectionError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Connecting failed: libpq's message says why (host, TLS, sign-in).
        case connectFailed
        /// The connect deadline passed.
        case connectTimedOut
        /// The connection broke while in use.
        case connectionLost
        /// The connection is busy with another statement, or closed.
        case notReady
        /// Sending failed (libpq's message says why).
        case sendFailed
    }

    public let kind: Kind
    /// libpq's message (`PQerrorMessage`), trimmed.
    public let message: String

    public init(_ kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}
