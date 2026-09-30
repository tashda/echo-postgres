import XCTest
@testable import PostgresKit

/// Kerberos (GSSAPI) sign-in against a real server and KDC (realm EXAMPLE.TEST), with alice's
/// ticket in a private cache. Start the server first; the tests are skipped without it:
///
///     eval "$(Tests/Fixtures/kerberos/start-server.sh)"
///     swift test --filter KerberosIntegrationTests
final class KerberosIntegrationTests: PostgresKitTestCase {
    private var port = 0

    override func setUp() async throws {
        try await super.setUp()
        guard let portText = ProcessInfo.processInfo.environment["POSTGRES_KRB_TEST_PORT"], let port = Int(portText),
              ProcessInfo.processInfo.environment["KRB5CCNAME"] != nil else {
            throw XCTSkip("Start Tests/Fixtures/kerberos/start-server.sh to run the Kerberos tests")
        }
        self.port = port
    }

    private func configuration(username: String = "alice", _ modify: (inout PostgresConfiguration) -> Void = { _ in }) -> PostgresConfiguration {
        var configuration = PostgresConfiguration(
            host: "localhost", port: port, database: "postgres", username: username, password: nil,
            applicationName: "KerberosIntegrationTests", connectTimeout: 5
        )
        modify(&configuration)
        return configuration
    }

    private func signedIn(_ client: PostgresClient) async throws -> (user: String?, gss: String?, principal: String?) {
        let result = try await client.simpleQueryResult(
            "SELECT current_user::text, g.gss_authenticated::text, g.principal FROM pg_stat_gssapi g WHERE g.pid = pg_backend_pid()"
        )
        let cells = try XCTUnwrap(result.rows.first).map { PostgresCellFormatter().stringValue(for: $0) }
        return (cells[0], cells[1], cells[2])
    }

    func testAliceSignsInWithHerKerberosTicket() async throws {
        let client = try await PostgresClient.connect(configuration: configuration(), logger: logger)
        defer { client.close() }
        let outcome = try await signedIn(client)
        XCTAssertEqual(outcome.user, "alice")
        XCTAssertEqual(outcome.gss, "true")
        XCTAssertEqual(outcome.principal, "alice@EXAMPLE.TEST")
    }

    func testAPinnedSessionSignsInWithKerberosToo() async throws {
        let session = try await PostgresSessionConnection.connect(configuration: configuration(), logger: logger)
        let result = try await session.queryResult("SELECT current_user::text")
        XCTAssertEqual(result.rows.first.flatMap { $0.first.flatMap(PostgresCellFormatter().stringValue(for:)) }, "alice")
        await session.close()
    }

    func testNoTicketSaysToSignInToKerberos() async throws {
        let cache = try XCTUnwrap(ProcessInfo.processInfo.environment["KRB5CCNAME"])
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("no-ticket-\(UUID().uuidString)").path
        setenv("KRB5CCNAME", "FILE:\(empty)", 1)
        defer { setenv("KRB5CCNAME", cache, 1) }
        do {
            let client = try await PostgresClient.connect(configuration: configuration(), logger: logger)
            client.close()
            XCTFail("there is no ticket in the empty cache")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No Kerberos ticket"), error.localizedDescription)
        }
    }

    func testAnUnknownServiceNameSaysSo() async {
        do {
            let client = try await PostgresClient.connect(configuration: configuration { $0.kerberosServiceName = "nosuchservice" }, logger: logger)
            client.close()
            XCTFail("the realm has no nosuchservice/localhost principal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not know the database service nosuchservice@localhost"), error.localizedDescription)
        }
    }

    func testKerberosTurnedOffSaysTheServerAsksForIt() async {
        do {
            let client = try await PostgresClient.connect(configuration: configuration { $0.kerberosServiceName = nil }, logger: logger)
            client.close()
            XCTFail("the server only offers Kerberos")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Kerberos"), error.localizedDescription)
        }
    }

    func testAPrincipalWithoutARoleIsRefusedByTheServer() async {
        do {
            let client = try await PostgresClient.connect(configuration: configuration(username: "bob"), logger: logger)
            client.close()
            XCTFail("alice's ticket does not sign in as bob")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}
