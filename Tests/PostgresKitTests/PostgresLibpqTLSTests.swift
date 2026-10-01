import Foundation
import PGLibpq
import PostgresKitTesting
import Testing
@testable import PostgresKit

/// TLS through libpq with the Kit's keywords, on the lab's TLS recipes
/// (`pg-18-tls-required`, `pg-17-tls-client-certificate`): `POSTGRES_TEST_TLS_URL` carries the
/// mode, the lab CA and, for certificate sign-in, the client certificate and key.
@Suite("PostgresKit TLS through libpq", .testServer("POSTGRES_TEST_TLS_URL"), .serialized)
struct PostgresLibpqTLSTests {
    private func connect(_ configuration: PostgresConfiguration) async throws -> PGConnection {
        let setup = try await configuration.libpqSetup(password: configuration.password)
        let connection = try await PGConnection.connect(setup.parameters, timeout: .seconds(15))
        withExtendedLifetime(setup) {}
        return connection
    }

    @Test func verifiesAgainstTheChosenCA() async throws {
        var configuration = try #require(TestServer.current).configuration
        configuration.sslMode = .verifyFull
        try #require(configuration.sslRootCertPath != nil, "the lab URL names its CA")
        let connection = try await connect(configuration)
        defer { Task { await connection.close() } }
        guard case .tls(let version, let cipher) = await connection.encryption else {
            Issue.record("not encrypted: \(await connection.encryption)")
            return
        }
        #expect(version?.hasPrefix("TLSv1.") == true)
        #expect(cipher?.isEmpty == false)
    }

    #if canImport(EchoTLS)
    @Test func keychainTrustDoesNotKnowTheLabCA() async throws {
        var configuration = try #require(TestServer.current).configuration
        configuration.sslMode = .verifyFull
        configuration.sslRootCertPath = nil
        do {
            let connection = try await connect(configuration)
            await connection.close()
            Issue.record("the lab CA is not in the Keychain; the connection must be refused")
        } catch let error as PGConnectionError {
            #expect(error.kind == .connectFailed)
            #expect(error.message.contains("certificate verify failed"))
        }
    }
    #endif

    @Test func requireEncryptsWithoutChecking() async throws {
        var configuration = try #require(TestServer.current).configuration
        configuration.sslMode = .require
        configuration.sslRootCertPath = nil
        let connection = try await connect(configuration)
        defer { Task { await connection.close() } }
        if case .tls = await connection.encryption {} else { Issue.record("require must encrypt") }
    }
}
