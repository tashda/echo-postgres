import Foundation
import NIOSSL

/// Client certificates for mutual TLS: a PEM or DER certificate and key (libpq `sslcert` /
/// `sslkey`), or one PKCS#12 file (`.p12` / `.pfx`) holding both. A key or PKCS#12 file protected
/// by a password is opened with `sslKeyPassword` (libpq `sslpassword`).
public enum PostgresClientCertificate {
    /// Whether the path names a PKCS#12 file, which holds the certificate and the key together.
    public static func isPKCS12(_ path: String) -> Bool {
        ["p12", "pfx"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Whether the key file (or PKCS#12 file) needs a password to be opened. PEM files are read by
    /// their header (`ENCRYPTED PRIVATE KEY`, `Proc-Type: 4,ENCRYPTED`); DER and PKCS#12 files are
    /// tried without one. False when the file can't be read.
    public static func keyNeedsPassword(atPath path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        if isPKCS12(path) {
            return (try? NIOSSLPKCS12Bundle(buffer: Array(data))) == nil
        }
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") {
            return text.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") || text.contains("Proc-Type: 4,ENCRYPTED")
        }
        return (try? NIOSSLPrivateKey(bytes: Array(data), format: .der)) == nil
    }

    /// Sets the certificate chain and key on `config`. With a PKCS#12 file as the certificate, the
    /// key comes from the same file and `keyPath` may be nil.
    static func apply(to config: inout TLSConfiguration, certPath: String?, keyPath: String?, keyPassword: String?) throws {
        guard let certPath else { return }
        if isPKCS12(certPath) {
            let bundle = try loadPKCS12(certPath, password: keyPassword)
            config.certificateChain = bundle.certificateChain.map { .certificate($0) }
            config.privateKey = .privateKey(bundle.privateKey)
            return
        }
        guard let keyPath else { return }
        do {
            config.certificateChain = try NIOSSLCertificate.fromPEMFile(certPath).map { .certificate($0) }
        } catch {
            throw PostgresTLSFileError(kind: .certificate, message: "Could not read the client certificate at \(certPath). It must be a PEM file, or a .p12/.pfx file.", underlying: error)
        }
        let keyFormat: NIOSSLSerializationFormats = keyPath.lowercased().hasSuffix(".der") ? .der : .pem
        do {
            if let keyPassword, !keyPassword.isEmpty {
                let bytes = Array(keyPassword.utf8)
                config.privateKey = .privateKey(try NIOSSLPrivateKey(file: keyPath, format: keyFormat) { setter in setter(bytes) })
            } else {
                config.privateKey = .privateKey(try NIOSSLPrivateKey(file: keyPath, format: keyFormat))
            }
        } catch {
            throw keyError(path: keyPath, what: "client key", password: keyPassword, underlying: error)
        }
    }

    private static func loadPKCS12(_ path: String, password: String?) throws -> NIOSSLPKCS12Bundle {
        do {
            if let password, !password.isEmpty {
                return try NIOSSLPKCS12Bundle(file: path, passphrase: Array(password.utf8))
            }
            return try NIOSSLPKCS12Bundle(file: path)
        } catch {
            throw keyError(path: path, what: "certificate file", password: password, underlying: error)
        }
    }

    /// Tells a missing or wrong password apart from a file that is not a key.
    private static func keyError(path: String, what: String, password: String?, underlying: any Error) -> PostgresTLSFileError {
        guard FileManager.default.isReadableFile(atPath: path) else {
            return PostgresTLSFileError(kind: .unreadable, message: "Could not open the \(what) at \(path).", underlying: underlying)
        }
        let needsPassword = keyNeedsPassword(atPath: path)
        switch (needsPassword, password?.isEmpty == false) {
        case (true, false):
            return PostgresTLSFileError(kind: .keyNeedsPassword, message: "The \(what) at \(path) is protected by a password. Enter the key password.", underlying: underlying)
        case (true, true):
            return PostgresTLSFileError(kind: .wrongKeyPassword, message: "The key password is wrong for \(path).", underlying: underlying)
        default:
            return PostgresTLSFileError(kind: .unreadable, message: "Could not read the \(what) at \(path): it is not a private key\(isPKCS12(path) ? " bundle" : "").", underlying: underlying)
        }
    }
}

/// A certificate or key file for TLS could not be read.
public struct PostgresTLSFileError: Error, LocalizedError, @unchecked Sendable {
    public enum Kind: Sendable, Equatable {
        /// The client certificate isn't a certificate file.
        case certificate
        /// The key is protected by a password and none was given.
        case keyNeedsPassword
        /// The key password doesn't open the key.
        case wrongKeyPassword
        /// The file is missing or isn't a key.
        case unreadable
    }

    public let kind: Kind
    public let message: String
    public let underlying: any Error
    public var errorDescription: String? { message }

    public init(kind: Kind = .unreadable, message: String, underlying: any Error) {
        self.kind = kind
        self.message = message
        self.underlying = underlying
    }
}
