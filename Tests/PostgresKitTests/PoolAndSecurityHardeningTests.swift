import Foundation
import Logging
import XCTest
@testable import PostgresKit

/// Pool configuration, startup parameters, server connections, error details and role passwords.
final class PoolAndSecurityHardeningTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        client = try await PostgresKit.PostgresClient.connect(configuration: TestEnv.configuration(applicationName: "HardeningTests"), logger: logger)
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    private func scalar(_ client: PostgresKit.PostgresClient, _ sql: String) async throws -> String? {
        let result = try await client.simpleQueryResult(sql)
        return result.rows.first.flatMap { row in row.first.flatMap { PostgresCellFormatter().stringValue(for: $0) } }
    }

    // MARK: - Configuration reaches the server

    func testApplicationNameIsSent() async throws {
        let value1 = try await scalar(client, "SELECT application_name FROM pg_stat_activity WHERE pid = pg_backend_pid()")
        XCTAssertEqual(value1, "HardeningTests")
    }

    func testPoolMaximumIsHonoured() async throws {
        let small = try await PostgresKit.PostgresClient.connect(
            configuration: TestEnv.configuration(pool: .init(minimum: 0, maximum: 2, idleTimeoutSeconds: 60)),
            logger: logger
        )
        defer { small.close() }
        let pids = try await withThrowingTaskGroup(of: Int32.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    let result = try await small.simpleQueryResult("SELECT pg_backend_pid(), pg_sleep(0.3)")
                    return try result.rows.first!.decode((Int32, String?).self).0
                }
            }
            var pids = Set<Int32>()
            for try await pid in group { pids.insert(pid) }
            return pids
        }
        XCTAssertLessThanOrEqual(pids.count, 2)
    }

    func testStatementTimeoutAppliesToPooledConnections() async throws {
        let timed = try await PostgresKit.PostgresClient.connect(configuration: TestEnv.configuration(statementTimeout: .milliseconds(250)), logger: logger)
        defer { timed.close() }
        let value2 = try await scalar(timed, "SHOW statement_timeout")
        XCTAssertEqual(value2, "250ms")
    }

    func testWithTransactionCommitsAndRollsBack() async throws {
        let table = "tx_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await client.simpleQueryResult("CREATE TABLE \(table) (id int)")
        defer { Task { [client = client!] in _ = try? await client.simpleQueryResult("DROP TABLE IF EXISTS \(table)") } }

        try await client.withTransaction { connection in
            _ = try await connection.simpleQuery("INSERT INTO \(table) VALUES (1)").collect()
        }
        do {
            try await client.withTransaction { connection in
                _ = try await connection.simpleQuery("INSERT INTO \(table) VALUES (2)").collect()
                throw CancellationError()
            }
        } catch is CancellationError {}
        let value3 = try await scalar(client, "SELECT string_agg(id::text, ',') FROM \(table)")
        XCTAssertEqual(value3, "1")
    }

    func testCancelBackendOfUnknownPid() async throws {
        let value4 = try await client.cancelBackend(pid: 999_999)
        XCTAssertFalse(value4)
    }

    // MARK: - Server connection

    func testConcurrentClientRequestsShareOnePool() async throws {
        let server = try await PostgresServerConnection.connect(configuration: TestEnv.configuration(), logger: logger)
        defer { Task { await server.closeAll() } }
        let clients = try await withThrowingTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<5 {
                group.addTask { ObjectIdentifier(try await server.client(for: "template1")) }
            }
            var identifiers = Set<ObjectIdentifier>()
            for try await identifier in group { identifiers.insert(identifier) }
            return identifiers
        }
        XCTAssertEqual(clients.count, 1)

        let session = try await server.makeSession()
        defer { Task { await session.close() } }
        XCTAssertGreaterThan(session.backendPID, 0)
    }

    func testReleasedClientIsClosedAndReplacedOnNextRequest() async throws {
        let server = try await PostgresServerConnection.connect(configuration: TestEnv.configuration(), logger: logger)
        defer { Task { await server.closeAll() } }
        let first = try await server.client(for: "template1")
        let same = try await server.client(for: "template1")
        XCTAssertTrue(first === same)

        await server.releaseClient(for: "template1")
        let second = try await server.client(for: "template1")
        XCTAssertFalse(first === second, "a released database connects again with a new client")
        let value = try await scalar(second, "SELECT current_database()")
        XCTAssertEqual(value, "template1")

        await server.releaseClient(for: server.connectedDatabase)
        let primary = try await server.client(for: server.connectedDatabase)
        XCTAssertTrue(primary === server.primaryClient, "the primary client is never released")
    }

    // MARK: - Errors

    func testErrorsCarryPositionHintAndDetail() async throws {
        do {
            _ = try await client.withConnection { try await $0.simpleQuery("SELECT * FROM no_such_table_xyz").collect() }
            XCTFail("expected an error")
        } catch let error as PostgresError {
            XCTAssertEqual(error.sqlState, "42P01")
            XCTAssertEqual(error.position, 15)
        }
        do {
            _ = try await client.withConnection { try await $0.simpleQuery("SELECT lower(1)").collect() }
            XCTFail("expected an error")
        } catch let error as PostgresError {
            XCTAssertNotNil(error.hint)
        }
    }

    // MARK: - Roles and passwords

    func testScramVerifierMatchesReferenceImplementation() {
        let verifier = PostgresPasswordHashing.scramSHA256Verifier(password: "p'ss\\w0rd", salt: Array(0..<16))
        XCTAssertEqual(verifier, "SCRAM-SHA-256$4096:AAECAwQFBgcICQoLDA0ODw==$MppofYf1pD8cpsrgN7SL7W8bawJwH7cmyFJvGo6tefI=:HhE0cdxttzVpm32w1FwT5gYLw3Jxj6Ir6Y9UYgdArTw=")
        XCTAssertNil(PostgresPasswordHashing.scramSHA256Verifier(password: "pässword"), "non-ASCII is left to the server's SASLprep")
    }

    func testPasswordsWithQuotesAreHashedAndWork() async throws {
        let role = "hardening_\(UInt32.random(in: 0..<UInt32.max))"
        let password = "it's a \\ \"secret\"; DROP ROLE postgres; --"
        _ = try await client.security.createUser(name: role, password: password, createDatabase: false, createRole: false)
        addTeardownBlock { [client = client!] in
            // The role's own sessions close with their pool; retry until the server lets it go.
            for _ in 0..<20 {
                if (try? await client.security.dropUser(name: role, ifExists: true)) != nil { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        let stored = try await scalar(client, "SELECT rolpassword FROM pg_authid WHERE rolname = '\(role)'")
        XCTAssertTrue(stored?.hasPrefix("SCRAM-SHA-256$4096:") == true, "the password is hashed client-side")

        let asRole = try await PostgresKit.PostgresClient.connect(configuration: TestEnv.configuration(username: role, password: password), logger: logger)
        defer { asRole.close() }
        let value5 = try await scalar(asRole, "SELECT current_user")
        XCTAssertEqual(value5, role)

        _ = try await client.security.alterUser(name: role, password: "second'one", encrypted: false)
        let plain = try await PostgresKit.PostgresClient.connect(configuration: TestEnv.configuration(username: role, password: "second'one"), logger: logger)
        plain.close()
    }
}
