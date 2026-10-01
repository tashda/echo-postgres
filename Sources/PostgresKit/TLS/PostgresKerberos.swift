import Foundation
#if canImport(EchoKerberos)
import EchoKerberos
#endif

/// Kerberos sign-in. libpq does the GSSAPI exchange itself, with the ticket the user already has
/// (kinit, Ticket Viewer, an Active Directory login) for the service principal
/// `<service>@<host>`; on macOS through Apple's GSS.framework.
public enum PostgresKerberos {
    /// Whether this build can sign in with Kerberos.
    public static var isAvailable: Bool {
        #if canImport(EchoKerberos)
        true
        #else
        false
        #endif
    }

    /// The user's current ticket. Local only (the credential cache); it never asks the KDC.
    public static func currentTicket() -> PostgresKerberosTicket {
        #if canImport(EchoKerberos)
        switch KerberosTicket.current() {
        case .valid(let principal, let expiresAt): .valid(principal: principal, expiresAt: expiresAt)
        case .expired(let principal): .expired(principal: principal)
        case .none: .none
        case .unavailable: .unavailable
        }
        #else
        .unavailable
        #endif
    }
}

/// The user's Kerberos ticket as this process sees it.
public enum PostgresKerberosTicket: Sendable, Equatable {
    case valid(principal: String, expiresAt: Date?)
    case expired(principal: String?)
    case none
    case unavailable

    public var userName: String? {
        switch self {
        case .valid(let principal, _), .expired(let principal?): principal.split(separator: "@").first.map(String.init)
        default: nil
        }
    }
}

/// Why Kerberos sign-in failed, in words someone can act on, with libpq's own text.
public struct PostgresKerberosError: Error, LocalizedError, Sendable {
    public enum Kind: Sendable, Equatable {
        /// There is no ticket (no kinit, no Ticket Viewer sign-in).
        case noTicket
        /// The ticket has expired.
        case expired
        /// The realm has no principal for the database service (wrong host or service name).
        case unknownService
        /// The computer's clock differs too much from the KDC's.
        case clockSkew
        case other
    }

    public let kind: Kind
    public let message: String
    /// libpq's GSSAPI text.
    public let details: String
    public var errorDescription: String? { details.isEmpty ? message : "\(message) (\(details))" }

    public init(kind: Kind, message: String, details: String) {
        self.kind = kind
        self.message = message
        self.details = details
    }
}
