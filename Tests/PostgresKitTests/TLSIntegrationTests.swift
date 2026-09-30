import XCTest
import Logging
@testable import PostgresKit

/// Every `sslmode` against a real server that only accepts TLS, with a private CA, a server
/// certificate for `localhost` (not `127.0.0.1`) and client certificates for `cert_user`.
///
/// Start the server first; the tests are skipped without it:
///
///     eval "$(Tests/Fixtures/tls/start-server.sh)"
///     swift test --filter TLSIntegrationTests
final class TLSIntegrationTests: PostgresKitTestCase {
    private var port = 0
    private var certs = ""

    override func setUp() async throws {
        try await super.setUp()
        guard let portText = ProcessInfo.processInfo.environment["POSTGRES_TLS_TEST_PORT"], let port = Int(portText),
              let certs = ProcessInfo.processInfo.environment["POSTGRES_TLS_TEST_CERTS"] else {
            throw XCTSkip("Start Tests/Fixtures/tls/start-server.sh to run the TLS tests")
        }
        self.port = port
        self.certs = certs
    }

    private func configuration(
        host: String = "localhost",
        username: String = "postgres",
        password: String? = "postgres",
        _ sslMode: PostgresSSLMode,
        _ modify: (inout PostgresConfiguration) -> Void = { _ in }
    ) -> PostgresConfiguration {
        var configuration = PostgresConfiguration(
            host: host, port: port, database: "postgres", username: username, password: password,
            sslMode: sslMode, applicationName: "TLSIntegrationTests", connectTimeout: 5
        )
        modify(&configuration)
        return configuration
    }

    private func file(_ name: String) -> String { "\(certs)/\(name)" }

    /// Connects, and returns whether the connection is encrypted and who signed in.
    private func connect(_ configuration: PostgresConfiguration) async throws -> (encrypted: Bool, user: String) {
        let client = try await PostgresClient.connect(configuration: configuration, logger: logger)
        defer { client.close() }
        let result = try await client.simpleQueryResult(
            "SELECT s.ssl::text, current_user::text FROM pg_stat_ssl s WHERE s.pid = pg_backend_pid()"
        )
        let formatter = PostgresCellFormatter()
        let cells = try XCTUnwrap(result.rows.first).map { formatter.stringValue(for: $0) }
        return (cells.first == "true", (cells.dropFirst().first ?? nil) ?? "")
    }

    /// Expects the connection to fail with a message containing `saying`.
    private func assertFails(_ configuration: PostgresConfiguration, _ why: String, saying expected: String,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await connect(configuration)
            XCTFail("expected the connection to fail: \(why)", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(expected), "\(why): \(error.localizedDescription)", file: file, line: line)
        }
    }

    // MARK: - Modes

    func testDisableIsRefusedByAServerThatRequiresTLS() async {
        await assertFails(configuration(.disable), "the server rejects unencrypted connections", saying: "no encryption")
    }

    func testAllowFallsBackToTLSWhenPlainIsRefused() async throws {
        let outcome = try await connect(configuration(.allow))
        XCTAssertTrue(outcome.encrypted)
    }

    func testPreferAndRequireEncryptWithoutCheckingTheCertificate() async throws {
        let prefer = try await connect(configuration(host: "127.0.0.1", .prefer))
        XCTAssertTrue(prefer.encrypted)
        let require = try await connect(configuration(host: "127.0.0.1", .require))
        XCTAssertTrue(require.encrypted)
    }

    func testRequireWithARootCertificateChecksTheIssuerAsLibpqDoes() async throws {
        let trusted = try await connect(configuration(host: "127.0.0.1", .require) { $0.sslRootCertPath = file("ca.crt") })
        XCTAssertTrue(trusted.encrypted)
        await assertFails(configuration(host: "127.0.0.1", .require) { $0.sslRootCertPath = file("other-ca.crt") },
                          "a root certificate that did not sign the server's certificate", saying: "could not be verified")
    }

    func testVerifyCAChecksTheIssuerButNotTheHostName() async throws {
        let outcome = try await connect(configuration(host: "127.0.0.1", .verifyCA) { $0.sslRootCertPath = file("ca.crt") })
        XCTAssertTrue(outcome.encrypted, "127.0.0.1 is not in the certificate, which verify-ca does not check")
        await assertFails(configuration(host: "127.0.0.1", .verifyCA) { $0.sslRootCertPath = file("other-ca.crt") },
                          "an unrelated CA", saying: "could not be verified")
        await assertFails(configuration(host: "127.0.0.1", .verifyCA), "no root certificate: the system roots do not know the test CA", saying: "could not be verified")
    }

    func testVerifyFullChecksTheHostName() async throws {
        let outcome = try await connect(configuration(host: "localhost", .verifyFull) { $0.sslRootCertPath = file("ca.crt") })
        XCTAssertTrue(outcome.encrypted)
        await assertFails(configuration(host: "127.0.0.1", .verifyFull) { $0.sslRootCertPath = file("ca.crt") },
                          "the certificate is for localhost, not 127.0.0.1", saying: "not issued for this host name")
    }

    // MARK: - Client certificates

    func testClientCertificateSignsInWithoutAPassword() async throws {
        let outcome = try await connect(configuration(username: "cert_user", password: nil, .verifyFull) {
            $0.sslRootCertPath = file("ca.crt")
            $0.sslCertPath = file("client.crt")
            $0.sslKeyPath = file("client.key")
        })
        XCTAssertTrue(outcome.encrypted)
        XCTAssertEqual(outcome.user, "cert_user")
    }

    func testClientCertificateIsRequiredForCertUser() async {
        await assertFails(configuration(username: "cert_user", password: nil, .verifyFull) { $0.sslRootCertPath = file("ca.crt") },
                          "pg_hba requires a client certificate for cert_user", saying: "client certificate")
    }

    func testEncryptedClientKeyOpensWithItsPassword() async throws {
        let outcome = try await connect(configuration(username: "cert_user", password: nil, .verifyFull) {
            $0.sslRootCertPath = file("ca.crt")
            $0.sslCertPath = file("client.crt")
            $0.sslKeyPath = file("client-encrypted.key")
            $0.sslKeyPassword = "correct-horse"
        })
        XCTAssertEqual(outcome.user, "cert_user")
    }

    func testWrongKeyPasswordSaysSo() async {
        do {
            _ = try await connect(configuration(username: "cert_user", password: nil, .verifyFull) {
                $0.sslRootCertPath = file("ca.crt")
                $0.sslCertPath = file("client.crt")
                $0.sslKeyPath = file("client-encrypted.key")
                $0.sslKeyPassword = "wrong"
            })
            XCTFail("a wrong key password must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("key password"), error.localizedDescription)
            XCTAssertEqual(certificateProblem(error), .wrongKeyPassword)
        }
    }

    func testEncryptedKeyWithoutItsPasswordAsksForIt() async {
        do {
            _ = try await connect(configuration(username: "cert_user", password: nil, .verifyFull) {
                $0.sslRootCertPath = file("ca.crt")
                $0.sslCertPath = file("client.crt")
                $0.sslKeyPath = file("client-encrypted.key")
            })
            XCTFail("an encrypted key needs its password")
        } catch {
            XCTAssertEqual(certificateProblem(error), .keyNeedsPassword, error.localizedDescription)
        }
    }

    func testKeyNeedsPasswordReadsTheFile() {
        XCTAssertFalse(PostgresClientCertificate.keyNeedsPassword(atPath: file("client.key")))
        XCTAssertTrue(PostgresClientCertificate.keyNeedsPassword(atPath: file("client-encrypted.key")))
        XCTAssertTrue(PostgresClientCertificate.keyNeedsPassword(atPath: file("client.p12")))
        XCTAssertTrue(PostgresClientCertificate.keyNeedsPassword(atPath: file("client-legacy.pfx")))
        XCTAssertFalse(PostgresClientCertificate.keyNeedsPassword(atPath: file("no-such-file.key")))
    }

    func testPKCS12FileSignsInWithoutASeparateKey() async throws {
        for bundle in ["client.p12", "client-legacy.pfx"] {
            let outcome = try await connect(configuration(username: "cert_user", password: nil, .verifyFull) {
                $0.sslRootCertPath = file("ca.crt")
                $0.sslCertPath = file(bundle)
                $0.sslKeyPassword = "correct-horse"
            })
            XCTAssertEqual(outcome.user, "cert_user", bundle)
        }
    }

    func testPKCS12PasswordProblemsSaySo() async {
        for (password, expected) in [(nil, PostgresTLSFileError.Kind.keyNeedsPassword), ("wrong", .wrongKeyPassword)] {
            do {
                _ = try await connect(configuration(username: "cert_user", password: nil, .verifyFull) {
                    $0.sslRootCertPath = file("ca.crt")
                    $0.sslCertPath = file("client.p12")
                    $0.sslKeyPassword = password
                })
                XCTFail("the .p12 needs its password")
            } catch {
                XCTAssertEqual(certificateProblem(error), expected, error.localizedDescription)
            }
        }
    }

    private func certificateProblem(_ error: any Error) -> PostgresTLSFileError.Kind? {
        if case .clientCertificate(let file)? = (error as? PostgresError)?.connectionProblem { return file.kind }
        return nil
    }

    // MARK: - Sessions over TLS

    func testSessionAndServerSideCancelWorkOverTLS() async throws {
        let config = configuration(.verifyFull) { $0.sslRootCertPath = file("ca.crt") }
        let session = try await PostgresSessionConnection.connect(configuration: config, logger: logger)
        let client = try await PostgresClient.connect(configuration: config, logger: logger)
        defer { client.close() }
        let started = ContinuousClock.now
        let running = Task { try await session.queryResult("SELECT pg_sleep(10)") }
        try await Task.sleep(for: .milliseconds(500))
        let sent = try await session.cancel(using: client)
        XCTAssertTrue(sent)
        _ = try? await running.value
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        let after = try await session.queryResult("SELECT 1")
        XCTAssertEqual(after.rows.count, 1, "the session is usable after the cancel")
        await session.close()
    }
}
