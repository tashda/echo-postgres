import Foundation
import PostgresKit
import PostgresKitTesting
import Testing

/// TLS against a server that requires it: `POSTGRES_TEST_TLS_URL`, whose `sslmode`, `sslrootcert`
/// and (for certificate logins) `sslcert`/`sslkey` the tests start from. TESTING.md has a
/// `docker run` for such a server. Key files without a server: ClientCertificateFileTests.
@Suite(.testServer("POSTGRES_TEST_TLS_URL"), .enabled(if: LabTLSRecipe.certificate == nil && !LabTLSRecipe.isOptional))
struct TLSTests {
    private var base: PostgresConfiguration {
        get throws { try #require(TestServer.current).configuration }
    }

    /// Connects, and returns whether the connection is encrypted and the client certificate's DN.
    private func connect(_ configuration: PostgresConfiguration) async throws -> (encrypted: Bool, clientDN: String?) {
        let client = try await PostgresClient.connect(configuration: configuration)
        defer { client.close() }
        let result = try await client.simpleQueryResult(
            "SELECT s.ssl::text, s.client_dn FROM pg_stat_ssl s WHERE s.pid = pg_backend_pid()")
        let row = Array(try #require(result.rows.first))
        let formatter = PostgresCellFormatter()
        return (formatter.stringValue(for: row[0]) == "true", formatter.stringValue(for: row[1]))
    }

    @Test func theURLsSettingsConnectEncrypted() async throws {
        #expect(try await connect(base).encrypted)
    }

    @Test func plaintextIsRefused() async throws {
        var configuration = try base
        configuration.sslMode = .disable
        await #expect(throws: (any Error).self) { _ = try await connect(configuration) }
    }

    @Test func allowFallsBackToTLSAndRequireDoesNotCheckTheCertificate() async throws {
        var configuration = try base
        configuration.sslRootCertPath = nil
        configuration.sslMode = .allow
        #expect(try await connect(configuration).encrypted)
        configuration.sslMode = .require
        #expect(try await connect(configuration).encrypted)
    }

    @Test func verifyModesCheckAgainstTheURLsCA() async throws {
        var configuration = try base
        guard configuration.sslRootCertPath != nil else { return } // the URL names no CA to check against
        configuration.sslMode = .verifyCA
        #expect(try await connect(configuration).encrypted)
        configuration.sslMode = .verifyFull
        #expect(try await connect(configuration).encrypted)
    }

    @Test func aCAThatDidNotSignTheServerIsRefused() async throws {
        var configuration = try base
        configuration.sslRootCertPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Support/certificates/unrelated-ca.pem").path
        configuration.sslMode = .verifyCA
        await #expect(throws: (any Error).self) { _ = try await connect(configuration) }
    }

    @Test func theURLsClientCertificateIsPresented() async throws {
        let configuration = try base
        guard configuration.sslCertPath != nil else { return } // the URL has no client certificate
        let outcome = try await connect(configuration)
        #expect(outcome.clientDN != nil, "the server saw no client certificate")
    }

    @Test func aSessionAndServerSideCancelWorkOverTLS() async throws {
        let configuration = try base
        let session = try await PostgresSessionConnection.connect(configuration: configuration)
        let client = try await PostgresClient.connect(configuration: configuration)
        defer { client.close() }
        let started = ContinuousClock.now
        let running = Task { try await session.queryResult("SELECT pg_sleep(10)") }
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await session.cancel(using: client))
        _ = try? await running.value
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(try await session.queryResult("SELECT 1").rows.count == 1, "the session is usable after the cancel")
        await session.close()
    }
}
