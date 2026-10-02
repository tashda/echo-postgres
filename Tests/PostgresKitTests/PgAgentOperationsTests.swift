import XCTest
import Logging
@testable import PostgresKit

/// pgAgent jobs. Needs the pgagent extension in the database `POSTGRES_TEST_URL` names (its path);
/// skipped without it.
final class PgAgentOperationsTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.server?.configuration.database ?? TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "PgAgentOperationsTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
        let installed = try await client.metadata.listExtensions().contains { $0.name == "pgagent" }
        if !installed { throw XCTSkip("pgagent is not installed in the database POSTGRES_TEST_URL names") }
    }

    override func tearDown() async throws {
        client?.close()
        try await super.tearDown()
    }

    func testMaskMarksTheListedValues() {
        XCTAssertEqual(PostgresPgAgentClient.mask([0, 2], 0..<4), "{t,f,t,f}")
        XCTAssertEqual(PostgresPgAgentClient.mask([], 1..<3), "{f,f}")
    }

    func testCreateListDisableAndDelete() async throws {
        let client = try XCTUnwrap(self.client)
        let name = "agent_test_\(UUID().uuidString.prefix(8))"
        let id = try await client.pgAgent.createJob(PgAgentJobDefinition(
            name: name, description: "Nightly maintenance",
            steps: [
                .init(name: "vacuum", code: "VACUUM ANALYZE"),
                .init(name: "report", kind: .batch, code: "echo done", onError: .ignore),
            ],
            schedules: [.init(name: "nightly", minutes: [30], hours: [2]), .init(name: "sundays", minutes: [0], hours: [6], weekdays: [0])]
        ))
        var job = try await client.pgAgent.listJobs().first { $0.id == id }
        XCTAssertEqual(job?.name, name)
        XCTAssertEqual(job?.stepCount, 2)
        XCTAssertEqual(job?.scheduleCount, 2)
        XCTAssertEqual(job?.jobClass, "Routine Maintenance")

        try await client.pgAgent.setEnabled(jobID: id, enabled: false)
        job = try await client.pgAgent.listJobs().first { $0.id == id }
        XCTAssertEqual(job?.isEnabled, false)

        try await client.pgAgent.deleteJob(id: id)
        let remaining = try await client.pgAgent.listJobs().contains { $0.id == id }
        XCTAssertFalse(remaining)
    }
}
