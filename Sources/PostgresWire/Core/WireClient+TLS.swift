import Foundation
import NIOCore
import NIOSSL
import PostgresNIO

// MARK: - TLS Configuration Mapping

extension PostgresWireClient {
    /// The NIOSSL configuration for an sslmode, or `nil` for `disable`.
    private static func makeTLSConfiguration(
        sslMode: PostgresSSLMode,
        sslRootCertPath: String?,
        sslCertPath: String?,
        sslKeyPath: String?,
        sslKeyPassword: String?
    ) throws -> TLSConfiguration? {
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        switch sslMode {
        case .disable:
            return nil
        case .require where sslRootCertPath != nil:
            // As libpq: with a root certificate, require checks that the server's certificate is
            // signed by it (like verify-ca).
            tlsConfig.certificateVerification = .noHostnameVerification
            if let sslRootCertPath { tlsConfig.trustRoots = .file(sslRootCertPath) }
        case .allow, .prefer, .require:
            tlsConfig.certificateVerification = .none
        case .verifyCA:
            tlsConfig.certificateVerification = .noHostnameVerification
            if let sslRootCertPath { tlsConfig.trustRoots = .file(sslRootCertPath) }
        case .verifyFull:
            tlsConfig.certificateVerification = .fullVerification
            if let sslRootCertPath { tlsConfig.trustRoots = .file(sslRootCertPath) }
        }
        try PostgresClientCertificate.apply(to: &tlsConfig, certPath: sslCertPath, keyPath: sslKeyPath, keyPassword: sslKeyPassword)
        return tlsConfig
    }

    /// Build `PostgresConnection.Configuration.TLS` from the sslMode spectrum.
    static func makeConnectionTLS(
        sslMode: PostgresSSLMode,
        sslRootCertPath: String?,
        sslCertPath: String?,
        sslKeyPath: String?,
        sslKeyPassword: String? = nil
    ) throws -> PostgresConnection.Configuration.TLS {
        guard let tlsConfig = try makeTLSConfiguration(
            sslMode: sslMode, sslRootCertPath: sslRootCertPath, sslCertPath: sslCertPath, sslKeyPath: sslKeyPath, sslKeyPassword: sslKeyPassword
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
        sslKeyPath: String?,
        sslKeyPassword: String? = nil
    ) throws -> PostgresClient.Configuration.TLS {
        guard let tlsConfig = try makeTLSConfiguration(
            sslMode: sslMode, sslRootCertPath: sslRootCertPath, sslCertPath: sslCertPath, sslKeyPath: sslKeyPath, sslKeyPassword: sslKeyPassword
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
