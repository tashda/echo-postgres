import XCTest
import Logging
@testable import PostgresKit

final class DatabaseOperationsTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "DatabaseOperationsTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() async throws {
        client?.close()
        try await super.tearDown()
    }

    /// PostgreSQL has no CREATE DATABASE IF NOT EXISTS; the driver checks first.
    func testCreateDatabaseIfNotExistsTwice() async throws {
        let client = try XCTUnwrap(self.client)
        let name = "ifne_\(UUID().uuidString.prefix(8).lowercased())"
        let existedBefore = try await client.admin.databaseExists(name)
        XCTAssertFalse(existedBefore)
        try await client.admin.createDatabase(name: name, ifNotExists: true)
        try await client.admin.createDatabase(name: name, ifNotExists: true)
        let existsAfter = try await client.admin.databaseExists(name)
        XCTAssertTrue(existsAfter)
        try await client.admin.dropDatabase(name: name)
    }
}
