import Foundation
import PGLibpq
import PostgresKitTesting
import Testing
@testable import PostgresKit

/// Which lab TLS server the run has (`SERVERLAB_RECIPE`); empty outside the lab.
enum LabTLSRecipe {
    static var name: String { ProcessInfo.processInfo.environment["SERVERLAB_RECIPE"] ?? "" }
    static var certificate: String? {
        ["expired-certificate", "self-signed", "wrong-host"].first { name.hasSuffix("-tls-\($0)") }
    }
    static var isOptional: Bool { name.hasSuffix("-tls-optional") }
}

/// The lab's certificate-check servers: modes that check the certificate refuse a bad one, `require`
/// encrypts anyway. libpq's verify-ca checks the chain only, so a certificate naming another host
/// passes it (Echo's sheet says so; D19 is MySQL's).
@Suite("PostgresKit certificate checks", .testServer("POSTGRES_TEST_TLS_URL"), .serialized,
       .enabled(if: LabTLSRecipe.certificate != nil))
struct PostgresTLSCertificateCheckTests {
    private func attempt(_ mode: PostgresSSLMode) async -> Bool {
        guard var configuration = TestServer.current?.configuration else { return false }
        configuration.sslMode = mode
        do {
            let setup = try await configuration.libpqSetup(password: configuration.password)
            let connection = try await PGConnection.connect(setup.parameters, timeout: .seconds(15))
            withExtendedLifetime(setup) {}
            await connection.close()
            return true
        } catch {
            return false
        }
    }

    @Test func requireEncryptsWhateverTheCertificate() async {
        #expect(await attempt(.require))
    }

    @Test func verifyFullRefusesABadCertificate() async {
        #expect(await !attempt(.verifyFull))
    }

    @Test func verifyCARefusesABadChainOnly() async {
        #expect(await attempt(.verifyCA) == (LabTLSRecipe.certificate == "wrong-host"))
    }
}

/// A server where TLS is up to the client (`pg-17-tls-optional`): each mode gets what it asks for.
@Suite("PostgresKit optional TLS", .testServer("POSTGRES_TEST_TLS_URL"), .enabled(if: LabTLSRecipe.isOptional))
struct PostgresTLSOptionalTests {
    private func encryption(_ mode: PostgresSSLMode) async throws -> PGConnection.Encryption {
        var configuration = try #require(TestServer.current).configuration
        configuration.sslMode = mode
        let setup = try await configuration.libpqSetup(password: configuration.password)
        let connection = try await PGConnection.connect(setup.parameters, timeout: .seconds(15))
        withExtendedLifetime(setup) {}
        defer { Task { await connection.close() } }
        return await connection.encryption
    }

    @Test func eachModeGetsWhatItAsksFor() async throws {
        if case .tls = try await encryption(.disable) { Issue.record("disable must not encrypt") }
        for mode in [PostgresSSLMode.prefer, .require, .verifyCA, .verifyFull] {
            if case .tls = try await encryption(mode) {} else { Issue.record("\(mode) must encrypt") }
        }
    }
}
