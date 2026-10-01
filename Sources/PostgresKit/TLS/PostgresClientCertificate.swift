import Foundation
#if canImport(EchoTLS)
import EchoTLS
#endif

/// Client certificates for mutual TLS: a PEM or DER certificate and key (libpq `sslcert` /
/// `sslkey`), or one PKCS#12 file (`.p12` / `.pfx`) holding both, opened with `sslKeyPassword`.
/// They are turned into the PEM files libpq reads by EchoTLS's `ClientCertificateFiles`.
public enum PostgresClientCertificate {
    /// Whether the path names a PKCS#12 file, which holds the certificate and the key together.
    public static func isPKCS12(_ path: String) -> Bool {
        ["p12", "pfx"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Whether the key file (or PKCS#12 file) needs a password to be opened. False when the file
    /// can't be read.
    public static func keyNeedsPassword(atPath path: String) -> Bool {
        #if canImport(EchoTLS)
        ClientCertificate.keyNeedsPassword(atPath: path)
        #else
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return text.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") || text.contains("Proc-Type: 4,ENCRYPTED")
        #endif
    }
}

/// A certificate or key file for TLS could not be read.
public struct PostgresTLSFileError: Error, LocalizedError, Sendable {
    public enum Kind: Sendable, Equatable {
        /// The client certificate isn't a certificate file.
        case certificate
        /// The key is protected by a password and none was given.
        case keyNeedsPassword
        /// The key password doesn't open the key.
        case wrongKeyPassword
        /// The file is missing or isn't a key (or holds a key type that can't be used).
        case unreadable
    }

    public let kind: Kind
    public let message: String
    public var errorDescription: String? { message }

    public init(kind: Kind = .unreadable, message: String) {
        self.kind = kind
        self.message = message
    }

    #if canImport(EchoTLS)
    init(_ error: ClientCertificateError) {
        let kind: Kind = switch error.kind {
        case .certificate: .certificate
        case .keyNeedsPassword: .keyNeedsPassword
        case .wrongKeyPassword: .wrongKeyPassword
        case .unreadable, .unsupportedKey: .unreadable
        }
        self.init(kind: kind, message: error.message)
    }
    #endif
}
