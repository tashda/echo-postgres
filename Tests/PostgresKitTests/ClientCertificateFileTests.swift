import Foundation
@testable import PostgresKit
import Testing

/// Client certificate files without a server: the TLS configuration is built (and fails) before a
/// connection is attempted. Files in Support/certificates: a self-signed client certificate and its
/// key as PEM, DER, encrypted PEM and PKCS#12 (modern AES and legacy 3DES), password correct-horse.
@Suite struct ClientCertificateFileTests {
    private static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Support/certificates")
    private func file(_ name: String) -> String { Self.directory.appendingPathComponent(name).path }

    private func tlsSetup(certificate: String, key: String? = nil, password: String? = nil) async throws {
        var configuration = PostgresConfiguration(host: "127.0.0.1", username: "postgres", password: nil, sslMode: .require,
                                                  sslCertPath: file(certificate), sslKeyPath: key.map(file))
        configuration.sslKeyPassword = password
        _ = try await configuration.libpqSetup(password: nil)
    }

    private func kind(_ body: () async throws -> Void) async -> PostgresTLSFileError.Kind? {
        do { try await body(); return nil } catch let error as PostgresTLSFileError { return error.kind } catch { return nil }
    }

    @Test func keyNeedsPasswordReadsTheFile() {
        #expect(!PostgresClientCertificate.keyNeedsPassword(atPath: file("client.key")))
        #expect(!PostgresClientCertificate.keyNeedsPassword(atPath: file("client.der")))
        #expect(PostgresClientCertificate.keyNeedsPassword(atPath: file("client-encrypted.key")))
        #expect(PostgresClientCertificate.keyNeedsPassword(atPath: file("client.p12")))
        #expect(PostgresClientCertificate.keyNeedsPassword(atPath: file("client-legacy.pfx")))
        #expect(!PostgresClientCertificate.keyNeedsPassword(atPath: file("no-such-file.key")))
    }

    @Test func keysOpenWithTheRightPassword() async throws {
        try await tlsSetup(certificate: "client.crt", key: "client.key")
        try await tlsSetup(certificate: "client.crt", key: "client.der")
        try await tlsSetup(certificate: "client.crt", key: "client-encrypted.key", password: "correct-horse")
        try await tlsSetup(certificate: "client.p12", password: "correct-horse")
        try await tlsSetup(certificate: "client-legacy.pfx", password: "correct-horse")
    }

    @Test func aMissingOrWrongPasswordSaysWhich() async {
        #expect(await kind { try await tlsSetup(certificate: "client.crt", key: "client-encrypted.key") } == .keyNeedsPassword)
        // An encrypted PEM key is decrypted by libpq when connecting; a wrong password shows then
        // ("could not decrypt SSL key", mapped to .wrongKeyPassword by PostgresConnectionMessages).
        #expect(await kind { try await tlsSetup(certificate: "client.crt", key: "client-encrypted.key", password: "wrong") } == nil)
        #expect(await kind { try await tlsSetup(certificate: "client.p12") } == .keyNeedsPassword)
        #expect(await kind { try await tlsSetup(certificate: "client.p12", password: "wrong") } == .wrongKeyPassword)
        #expect(await kind { try await tlsSetup(certificate: "client.crt", key: "no-such-file.key") } == .unreadable)
    }
}
