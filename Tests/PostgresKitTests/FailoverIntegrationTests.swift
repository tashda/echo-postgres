import Foundation
import XCTest
@testable import PostgresKit

/// The pool moves to another configured host when its server goes away or is demoted to
/// read-only, instead of hanging and then failing (PostgresNIO alone waits 60 s and never tries
/// another host). Start the servers first; the tests are skipped without them:
///
///     eval "$(Tests/Fixtures/failover/start-servers.sh)"
///     swift test --filter FailoverIntegrationTests
final class FailoverIntegrationTests: PostgresKitTestCase {
    private var portA = 0, portB = 0
    private var containerA = "", containerB = ""

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        guard let a = env["POSTGRES_FAILOVER_PORT_A"].flatMap(Int.init), let b = env["POSTGRES_FAILOVER_PORT_B"].flatMap(Int.init),
              let ca = env["POSTGRES_FAILOVER_CONTAINER_A"], let cb = env["POSTGRES_FAILOVER_CONTAINER_B"] else {
            throw XCTSkip("Start Tests/Fixtures/failover/start-servers.sh to run the failover tests")
        }
        (portA, portB, containerA, containerB) = (a, b, ca, cb)
        // Each test starts from both servers running and writable.
        try docker("start", containerA)
        try docker("start", containerB)
        try waitUntilReady(containerA)
        try waitUntilReady(containerB)
        try setReadOnly(containerA, false)
        try setReadOnly(containerB, false)
    }

    // MARK: - Helpers

    @discardableResult
    private func docker(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func waitUntilReady(_ container: String) throws {
        for _ in 0..<60 {
            if try docker("exec", container, "pg_isready", "-U", "postgres", "-h", "127.0.0.1").contains("accepting") { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// What a failover does to a primary that stays up: it becomes read-only.
    private func setReadOnly(_ container: String, _ readOnly: Bool) throws {
        try docker("exec", container, "psql", "-U", "postgres", "-qAt",
                   "-c", "ALTER SYSTEM SET default_transaction_read_only = \(readOnly ? "on" : "off")",
                   "-c", "SELECT pg_reload_conf()")
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func configuration(_ attributes: PostgresTargetSessionAttributes = .any, twoHosts: Bool = true) -> PostgresConfiguration {
        var configuration = PostgresConfiguration(
            host: "127.0.0.1", port: portA, database: "postgres", username: "postgres", password: "postgres",
            applicationName: "FailoverIntegrationTests", connectTimeout: 3
        )
        if twoHosts { configuration.additionalHosts = [PostgresHost(host: "127.0.0.1", port: portB)] }
        configuration.targetSessionAttributes = attributes
        return configuration
    }

    private func serverPort(_ client: PostgresClient) async throws -> String? {
        let result = try await client.simpleQueryResult("SELECT inet_server_port()::text")
        return result.rows.first.flatMap { $0.first.flatMap(PostgresCellFormatter().stringValue(for:)) }
    }

    // MARK: - Tests

    func testPoolMovesToTheNextHostWhenItsServerStops() async throws {
        let client = try await PostgresClient.connect(configuration: configuration(), logger: logger)
        defer { client.close() }
        let first = try await serverPort(client)
        XCTAssertEqual(first, "5432")
        XCTAssertEqual(client.wire.resolvedConfiguration.port, portA)

        try docker("stop", "-t", "0", containerA)
        let started = ContinuousClock.now
        _ = try await serverPort(client)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(20), "fails over after connectTimeout, not PostgresNIO's 60 s")
        XCTAssertEqual(client.wire.resolvedConfiguration.port, portB)
    }

    func testHostChangesReportsWhereThePoolMoved() async throws {
        let client = try await PostgresClient.connect(configuration: configuration(), logger: logger)
        defer { client.close() }
        _ = try await serverPort(client)
        XCTAssertEqual(client.currentHost, PostgresHost(host: "127.0.0.1", port: portA))
        let changes = client.hostChanges()
        let first = Task { () -> PostgresHostChange? in
            for await change in changes { return change }
            return nil
        }

        try docker("stop", "-t", "0", containerA)
        _ = try await serverPort(client)
        let reported = await first.value
        let change = try XCTUnwrap(reported)
        XCTAssertEqual(change.from, PostgresHost(host: "127.0.0.1", port: portA))
        XCTAssertEqual(change.to, PostgresHost(host: "127.0.0.1", port: portB))
        XCTAssertTrue(change.reason.contains("Can't reach the server"), change.reason)
        XCTAssertEqual(client.currentHost, change.to)
    }

    func testProbeHostsChecksEveryServer() async throws {
        let both = await PostgresClient.probeHosts(configuration: configuration(), logger: logger)
        XCTAssertEqual(both.map(\.host.port), [portA, portB])
        XCTAssertEqual(both.map(\.role), [.primary, .primary], "neither fixture server is in recovery")

        try docker("stop", "-t", "0", containerB)
        let oneDown = await PostgresClient.probeHosts(configuration: configuration(), logger: logger)
        XCTAssertEqual(oneDown.first?.role, .primary)
        XCTAssertNil(oneDown.last?.role)
        XCTAssertNotNil(oneDown.last?.error)
    }

    func testReadWritePoolMovesOffADemotedPrimary() async throws {
        let client = try await PostgresClient.connect(configuration: configuration(.readWrite), logger: logger)
        defer { client.close() }
        _ = try await client.simpleQueryResult("CREATE TABLE IF NOT EXISTS failover_t (id int)")
        XCTAssertEqual(client.wire.resolvedConfiguration.port, portA)

        try setReadOnly(containerA, true)   // A is demoted; B stays writable
        // A single statement through query() is rejected by A and run again on B.
        let rows = try await client.wire.query(WireQuery(sql: "CREATE TABLE IF NOT EXISTS failover_t (id int)"))
        for try await _ in rows {}
        XCTAssertEqual(client.wire.resolvedConfiguration.port, portB)

        // Work inside withConnection that has started is never run twice: that call fails, the next one works.
        try setReadOnly(containerB, true)
        try setReadOnly(containerA, false)
        do {
            _ = try await client.simpleQueryResult("CREATE TABLE IF NOT EXISTS failover_t2 (id int)")
            XCTFail("B is read-only now")
        } catch {}
        _ = try await client.simpleQueryResult("CREATE TABLE IF NOT EXISTS failover_t2 (id int)")
        XCTAssertEqual(client.wire.resolvedConfiguration.port, portA)
    }

    func testASingleUnreachableHostFailsWithinTheConnectTimeoutAndSaysWhy() async throws {
        let client = try await PostgresClient.connect(configuration: configuration(twoHosts: false), logger: logger)
        defer { client.close() }
        _ = try await serverPort(client)
        try docker("stop", "-t", "0", containerA)
        let started = ContinuousClock.now
        do {
            _ = try await serverPort(client)
            XCTFail("the only server is stopped")
        } catch {
            XCTAssertLessThan(ContinuousClock.now - started, .seconds(20))
            XCTAssertFalse(error.localizedDescription.contains("CircuitBreaker"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Can't reach the server at 127.0.0.1:\(portA)"), error.localizedDescription)
        }
    }

    func testTheClientComesBackWhenTheServerReturns() async throws {
        let client = try await PostgresClient.connect(configuration: configuration(twoHosts: false), logger: logger)
        defer { client.close() }
        try docker("stop", "-t", "0", containerA)
        _ = try? await serverPort(client)
        try docker("start", containerA)
        try waitUntilReady(containerA)
        do {
            let port = try await serverPort(client)
            XCTAssertEqual(port, "5432")
        } catch {
            XCTFail("after the server returned: \(String(reflecting: error))")
        }
    }
}
