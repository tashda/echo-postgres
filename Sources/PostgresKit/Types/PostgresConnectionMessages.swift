import Foundation
import PGLibpq

/// Echo's sentences for connection failures, chosen from libpq's message (which stays available as
/// the error's detail, decision D15). The sentences are the ones Echo showed before the switch to
/// libpq (`baseline/errors-postgres.json`).
enum PostgresConnectionMessages {
    static func explain(_ error: PGConnectionError) -> (sentence: String, problem: PostgresConnectionProblem?) {
        let text = error.message.lowercased()
        switch error.kind {
        case .connectTimedOut:
            return ("Connection timed out. The server may be unreachable.", nil)
        case .connectionLost:
            return ("The server closed the connection unexpectedly.", nil)
        case .notReady:
            return (error.message.isEmpty ? "The connection is not ready." : error.message, nil)
        case .connectFailed, .sendFailed:
            break
        }
        if let kerberos = kerberosError(text, original: error.message) {
            return (kerberos.message, .kerberos(kerberos))
        }
        if text.contains("no password supplied") || text.contains("password is required") {
            return ("The server requires a password but none was provided.", .passwordRequired)
        }
        if text.contains("password authentication failed") {
            return (firstLine(of: error.message, droppingPrefix: true), nil)
        }
        if text.contains("could not translate host name") || text.contains("nodename nor servname") || text.contains("name or service not known") {
            return ("Could not resolve hostname. Check the server address.", nil)
        }
        if text.contains("connection refused") {
            return ("Connection refused. The server may not be running or the port may be wrong.", nil)
        }
        if text.contains("timeout expired") || text.contains("timed out") {
            return ("Connection timed out. The server may be unreachable.", nil)
        }
        if text.contains("network is unreachable") || text.contains("no route to host") {
            return ("Network is unreachable.", nil)
        }
        if let tls = tlsSentence(text) { return (tls, nil) }
        if text.contains("could not decrypt ssl key") || text.contains("bad decrypt") {
            let file = PostgresTLSFileError(kind: .wrongKeyPassword, message: "The key password is wrong.")
            return (file.message, .clientCertificate(file))
        }
        return (firstLine(of: error.message, droppingPrefix: true), nil)
    }

    /// Certificate and handshake failures, in words someone can act on.
    static func tlsSentence(_ text: String) -> String? {
        if text.contains("does not match host name") || text.contains("server certificate for") {
            return "The server's certificate is not issued for this host name. Connect with the name in the certificate, or use sslmode verify-ca, which checks the issuer but not the name."
        }
        if text.contains("certificate has expired") || text.contains("certificate expired") {
            return "The server's certificate has expired."
        }
        if text.contains("certificate verify failed") || text.contains("self-signed certificate") || text.contains("unable to get local issuer") {
            return "The server's certificate could not be verified: it is not signed by the root certificate given (sslrootcert) or by one the system trusts."
        }
        if text.contains("tlsv1 alert unknown ca") || text.contains("alert unknown ca") {
            return "The server did not accept the client certificate: it is not signed by a certificate authority the server trusts."
        }
        if text.contains("server does not support ssl") {
            return "The server does not support SSL/TLS connections."
        }
        if text.contains("wrong version number") || text.contains("unsupported protocol") || text.contains("no protocols available") {
            return "Echo and the server could not agree on a TLS version."
        }
        if text.contains("ssl error") || text.contains("handshake") {
            return "The TLS handshake with the server failed."
        }
        return nil
    }

    /// GSSAPI failures from libpq (Apple's GSS.framework wording and MIT's).
    static func kerberosError(_ text: String, original: String) -> PostgresKerberosError? {
        guard text.contains("gssapi") || text.contains("kerberos") else { return nil }
        let kind: PostgresKerberosError.Kind
        if text.contains("credential for asked mech-type mech not found") || text.contains("no kerberos credentials available")
            || text.contains("no credentials cache") || text.contains("credentials cache file") {
            kind = .noTicket
        } else if text.contains("expired") {
            kind = .expired
        } else if text.contains("server not found in kerberos database") || text.contains("unknown server") {
            kind = .unknownService
        } else if text.contains("clock skew") {
            kind = .clockSkew
        } else {
            kind = .other
        }
        let message: String = switch kind {
        case .noTicket: "No Kerberos ticket. Sign in with Ticket Viewer (or kinit) and connect again."
        case .expired: "The Kerberos ticket has expired. Renew it in Ticket Viewer (or kinit) and connect again."
        case .unknownService: "The Kerberos realm has no service principal for this server. Check the host name and the Kerberos service name."
        case .clockSkew: "This Mac's clock differs too much from the Kerberos server's. Set the date and time automatically and connect again."
        case .other: "Kerberos sign-in failed."
        }
        return PostgresKerberosError(kind: kind, message: message, details: firstLine(of: original, droppingPrefix: false))
    }

    /// libpq's message without the `connection to server at "…", port …failed:` prefix lines.
    static func firstLine(of message: String, droppingPrefix: Bool) -> String {
        var lines = message.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if droppingPrefix, let first = lines.first, let range = first.range(of: "failed: ") {
            lines[0] = String(first[range.upperBound...])
        }
        let line = lines.first ?? message
        guard let first = line.first else { return line }
        return first.uppercased() + line.dropFirst()
    }
}
