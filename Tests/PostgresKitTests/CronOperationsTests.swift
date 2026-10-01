import XCTest
import Logging
@testable import PostgresKit

/// pg_cron jobs. Needs pg_cron preloaded and created in the test database: echo-server-lab
/// `pg-17-third-party-extensions` (POSTGRES_DATABASE=labdata).
final class CronOperationsTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "CronOperationsTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
        let installed = try await client.metadata.listExtensions().contains { $0.name == "pg_cron" }
        if !installed { throw XCTSkip("pg_cron is not installed in \(TestEnv.database)") }
    }

    override func tearDown() async throws {
        client?.close()
        try await super.tearDown()
    }

    func testScheduleListPauseAndUnschedule() async throws {
        let client = try XCTUnwrap(self.client)
        let name = "cron_test_\(UUID().uuidString.prefix(8).lowercased())"
        let id = try await client.cron.schedule(name: name, schedule: "*/5 * * * *", command: "SELECT 1")
        var job = try await client.cron.listJobs().first { $0.id == id }
        XCTAssertEqual(job?.name, name)
        XCTAssertEqual(job?.schedule, "*/5 * * * *")
        XCTAssertEqual(job?.isActive, true)

        try await client.cron.setActive(jobID: id, active: false)
        job = try await client.cron.listJobs().first { $0.id == id }
        XCTAssertEqual(job?.isActive, false)

        let removed = try await client.cron.unschedule(name: name)
        XCTAssertTrue(removed)
        let remaining = try await client.cron.listJobs().contains { $0.id == id }
        XCTAssertFalse(remaining)
    }

    func testIntervalJobRunsAndIsRecorded() async throws {
        let client = try XCTUnwrap(self.client)
        let name = "cron_run_\(UUID().uuidString.prefix(8).lowercased())"
        let id = try await client.cron.schedule(name: name, schedule: "1 seconds", command: "SELECT 42")
        defer { Task { [client] in _ = try? await client.cron.unschedule(name: name) } }
        var runs: [PostgresCronRun] = []
        for _ in 1...20 where runs.isEmpty {
            try await Task.sleep(for: .milliseconds(500))
            runs = try await client.cron.listRuns(limit: 50).filter { $0.jobID == id && $0.status == "succeeded" }
        }
        XCTAssertFalse(runs.isEmpty, "no succeeded run of job \(id)")
    }
}
