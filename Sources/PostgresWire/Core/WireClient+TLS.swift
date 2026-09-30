import Foundation
import NIOCore
import NIOSSL
import PostgresNIO

// MARK: - TLS Configuration Mapping

extension PostgresWireClient {
    /// Apply client certificate and key to a TLS configuration for mTLS.
    private static func applyClientCertificate(
        to config: inout TLSConfiguration,
        certPath: String?,
        keyPath: String?
    ) throws {
        guard let certPath, let keyPath else { return }
        config.certificateChain = try NIOSSLCertificate.fromPEMFile(certPath).map { .certificate($0) }
        let keyFormat: NIOSSLSerializationFormats = keyPath.lowercased().hasSuffix(".der") ? .der : .pem
        config.privateKey = .privateKey(try NIOSSLPrivateKey(file: keyPath, format: keyFormat))
    }

    /// The NIOSSL configuration for an sslmode, or `nil` for `disable`.
    private static func makeTLSConfiguration(
        sslMode: PostgresSSLMode,
        sslRootCertPath: String?,
        sslCertPath: String?,
        sslKeyPath: String?
    ) throws -> TLSConfiguration? {
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        switch sslMode {
        case .disable:
            return nil
        case .allow, .prefer, .require:
            tlsConfig.certificateVerification = .none
        case .verifyCA:
            tlsConfig.certificateVerification = .noHostnameVerification
            if let sslRootCertPath { tlsConfig.trustRoots = .file(sslRootCertPath) }
        case .verifyFull:
            tlsConfig.certificateVerification = .fullVerification
            if let sslRootCertPath { tlsConfig.trustRoots = .file(sslRootCertPath) }
        }
        try applyClientCertificate(to: &tlsConfig, certPath: sslCertPath, keyPath: sslKeyPath)
        return tlsConfig
    }

    /// Build `PostgresConnection.Configuration.TLS` from the sslMode spectrum.
    static func makeConnectionTLS(
        sslMode: PostgresSSLMode,
        sslRootCertPath: String?,
        sslCertPath: String?,
        sslKeyPath: String?
    ) throws -> PostgresConnection.Configuration.TLS {
        guard let tlsConfig = try makeTLSConfiguration(
            sslMode: sslMode, sslRootCertPath: sslRootCertPath, sslCertPath: sslCertPath, sslKeyPath: sslKeyPath
        ) else { return .disable }
        let context = try NIOSSLContext(configuration: tlsConfig)
        switch sslMode {
        case .allow, .prefer: return .prefer(context)
        default: return .require(context)
        }
    }

    /// Build `PostgresClient.Configuration.TLS` (pool-level) from the sslMode spectrum.
    static func makePoolTLS(
        sslMode: PostgresSSLMode,
        sslRootCertPath: String?,
        sslCertPath: String?,
        sslKeyPath: String?
    ) throws -> PostgresClient.Configuration.TLS {
        guard let tlsConfig = try makeTLSConfiguration(
            sslMode: sslMode, sslRootCertPath: sslRootCertPath, sslCertPath: sslCertPath, sslKeyPath: sslKeyPath
        ) else { return .disable }
        switch sslMode {
        case .allow, .prefer: return .prefer(tlsConfig)
        default: return .require(tlsConfig)
        }
    }
}

// MARK: - DNS Pre-Resolution

extension PostgresWireClient {
    /// Resolve hostname before attempting a connection. Fails immediately for
    /// non-existent hosts, typos, and invalid addresses — no need to wait for
    /// the TCP connect timeout.
    static func resolveHostname(_ host: String, port: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                #if canImport(Darwin)
                hints.ai_socktype = SOCK_STREAM
                #else
                hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
                #endif
                hints.ai_family = AF_UNSPEC

                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, String(port), &hints, &result)
                if let result {
                    freeaddrinfo(result)
                }

                if status != 0 {
                    continuation.resume(throwing: DNSResolutionError(host: host))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

/// Error thrown when DNS resolution fails for a hostname.
struct DNSResolutionError: Error, LocalizedError {
    let host: String

    var errorDescription: String? {
        "Could not resolve hostname '\(host)'. Check the server address."
    }
}
