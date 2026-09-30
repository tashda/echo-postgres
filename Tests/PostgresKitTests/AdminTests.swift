import XCTest
import Logging
import PostgresKit

final class AdminTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else {
            throw XCTSkip("POSTGRES_HOST not set. Copy .env.example to .env and configure connection.")
        }
        let config = PostgresConfiguration(
            host: TestEnv.host,
            port: TestEnv.port,
            database: TestEnv.database,
            username: TestEnv.username,
            password: TestEnv.password,
            useTLS: TestEnv.useTLS,
            applicationName: "AdminTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() async throws {
        client?.close()
    }

    // MARK: - VACUUM

    func testVacuumDatabase() async throws {
        // VACUUM the whole database — should complete without error
        try await client.maintenance.vacuum()
    }

    func testVacuumWithAnalyze() async throws {
        try await client.maintenance.vacuum(analyze: true)
    }

    func testVacuumSpecificTable() async throws {
        // Create a temp table, vacuum it, drop it
        try await client.admin.createTable(name: "admin_vacuum_tmp", columns: [
            .integer(name: "id")
        ], temporary: true)
        try await client.bulk.insert(into: "admin_vacuum_tmp", columns: ["id"], values: [[1], [2], [3]])
        try await client.bulk.delete(from: "admin_vacuum_tmp")
        // VACUUM on a temp table is a no-op but must not throw
        try await client.maintenance.vacuum(table: "admin_vacuum_tmp")
    }

    // MARK: - ANALYZE

    func testAnalyzeDatabase() async throws {
        try await client.maintenance.analyze()
    }

    func testAnalyzeSpecificTable() async throws {
        try await client.admin.createTable(name: "admin_analyze_tmp", columns: [
            .integer(name: "id"),
            .text(name: "name")
        ], temporary: true)
        try await client.bulk.insert(into: "admin_analyze_tmp", columns: ["id", "name"], values: [[1, "a"], [2, "b"]])
        try await client.maintenance.analyze(table: "admin_analyze_tmp")
    }

    // MARK: - REINDEX

    func testReindexDatabase() async throws {
        let db = TestEnv.database
        try await client.maintenance.reindex(database: db)
    }

    // MARK: - SHOW / SET

    func testShowWorkMem() async throws {
        let value = try await client.serverConfig.show("work_mem")
        XCTAssertNotNil(value, "SHOW work_mem should return a value")
    }

    func testShowStatementTimeout() async throws {
        let value = try await client.serverConfig.show("statement_timeout")
        XCTAssertNotNil(value)
    }

    func testSetAndRestoreWorkMem() async throws {
        let original = try await client.serverConfig.show("work_mem")
        let testValue = "32MB"

        try await client.serverConfig.set("work_mem", value: testValue)
        let updated = try await client.serverConfig.show("work_mem")
        XCTAssertNotNil(updated)
        // The value may be normalised by Postgres (e.g. "32768kB") so just check it's non-nil

        // Restore
        if let original {
            try await client.serverConfig.set("work_mem", value: original)
        }
        let restored = try await client.serverConfig.show("work_mem")
        XCTAssertEqual(restored, original)
    }

    func testSetEnableSeqScan() async throws {
        try await client.serverConfig.set("enable_seqscan", value: "off")
        let v = try await client.serverConfig.show("enable_seqscan")
        XCTAssertEqual(v?.lowercased(), "off")
        try await client.serverConfig.set("enable_seqscan", value: "on")
    }
}
