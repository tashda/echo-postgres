import Foundation
import PostgresNIO

/// Internal error parsing logic for converting PostgresNIO errors into user-friendly messages.
internal enum PostgresErrorParsing {
    /// Extract a human-readable message from a PSQLError that has no serverInfo.
    static func extractMessage(from error: PSQLError) -> String {
        let underlying = error.underlying
        switch error.code {
        case .connectionError: return describeConnectionError(underlying)
        case .failedToAddSSLHandler:
            if let underlying { return "TLS error: \(underlyingDescription(underlying))" }
            return "Failed to establish a TLS connection to the server."
        case .sslUnsupported: return "The server does not support SSL/TLS connections."
        case .receivedUnencryptedDataAfterSSLRequest: return "Received unencrypted data after requesting an SSL connection."
        case .authMechanismRequiresPassword: return "The server requires a password but none was provided."
        case .unsupportedAuthMechanism: return "The server requested an authentication mechanism that is not supported."
        case .saslError:
            if let underlying { return "Authentication failed: \(underlyingDescription(underlying))" }
            return "SASL authentication failed."
        case .serverClosedConnection:
            if let underlying { return "The server closed the connection: \(underlyingDescription(underlying))" }
            return "The server closed the connection unexpectedly."
        case .clientClosedConnection: return "The connection was closed by the client."
        case .uncleanShutdown: return "The connection was shut down unexpectedly."
        case .queryCancelled: return "The query was cancelled."
        case .tooManyParameters: return "Too many parameters in the query."
        case .poolClosed: return "The connection pool has been closed."
        case .messageDecodingFailure:
            if let underlying { return "Failed to decode a message from the server: \(underlyingDescription(underlying))" }
            return "Failed to decode a message from the server."
        case .unexpectedBackendMessage: return "Received an unexpected message from the server."
        case .invalidCommandTag: return "The server returned an invalid command tag."
        default:
            if let underlying { return underlyingDescription(underlying) }
            return String(reflecting: error)
        }
    }

    /// Produce a human-readable description of a connection error's underlying cause.
    static func describeConnectionError(_ underlying: (any Error)?) -> String {
        guard let underlying else { return "Could not connect to the server." }
        if let ioError = underlying as? IOError { return describeIOError(ioError) }
        let desc = String(describing: underlying).lowercased()
        if desc.contains("channelerror") || desc.contains("connecttimeout") { return "Connection timed out. The server may be unreachable." }
        if desc.contains("name or service not known") || desc.contains("nodename nor servname provided") ||
           desc.contains("could not resolve") || desc.contains("getaddrinfo") || desc.contains("no such host") {
            return "Could not resolve hostname. Check the server address."
        }
        if desc.contains("connection refused") { return "Connection refused. The server may not be running or the port may be wrong." }
        if desc.contains("timed out") || desc.contains("timeout") { return "Connection timed out. The server may be unreachable." }
        if desc.contains("network is unreachable") || desc.contains("no route to host") { return "Network is unreachable." }
        if let tls = describeTLSFailure(desc) { return tls }
        return "Could not connect to the server: \(String(describing: underlying))"
    }

    /// Certificate and handshake failures, in words someone can act on (the TLS library's text
    /// follows in the log, not in the message).
    static func describeTLSFailure(_ desc: String) -> String? {
        if desc.contains("failedtovalidatehostname") || desc.contains("hostname_mismatch") {
            return "The server's certificate is not issued for this host name. Connect with the name in the certificate, or use sslmode verify-ca, which checks the issuer but not the name."
        }
        if desc.contains("certificate_expired") || desc.contains("certificate has expired") {
            return "The server's certificate has expired."
        }
        if desc.contains("certificate_verify_failed") || desc.contains("unable to get local issuer") || desc.contains("self signed") {
            return "The server's certificate could not be verified: it is not signed by the root certificate given (sslrootcert) or by one the system trusts."
        }
        if desc.contains("tlsv1_alert_unknown_ca") || desc.contains("alert unknown ca") {
            return "The server did not accept the client certificate: it is not signed by a certificate authority the server trusts."
        }
        if desc.contains("wrong_version_number") || desc.contains("unsupported_protocol") || desc.contains("no_protocols_available") {
            return "Echo and the server could not agree on a TLS version."
        }
        if desc.contains("handshakefailed") {
            return "The TLS handshake with the server failed."
        }
        return nil
    }

    /// Translate IOError errno codes into user-friendly messages.
    static func describeIOError(_ error: IOError) -> String {
        switch error.errnoCode {
        case EPERM: return "Connection failed. The server may not be running or the address is unreachable."
        case EACCES: return "Permission denied when connecting to the server."
        case ENETUNREACH: return "Network is unreachable."
        case ETIMEDOUT: return "Connection timed out. The server may be unreachable."
        case ECONNREFUSED: return "Connection refused. The server may not be running or the port may be wrong."
        case EHOSTDOWN: return "The server appears to be down."
        case EHOSTUNREACH: return "No route to host. The server may be unreachable."
        default: return "Connection failed: \(String(describing: error))"
        }
    }

    /// Get a useful string from an underlying error.
    static func underlyingDescription(_ error: any Error) -> String {
        let localized = error.localizedDescription
        if localized.contains("PSQLError") && localized.contains("Generic description") { return String(reflecting: error) }
        return localized
    }
}
