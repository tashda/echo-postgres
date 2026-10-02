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

    /// A unique index built CONCURRENTLY over duplicates fails and stays behind, invalid.
    func testFailedConcurrentIndexIsInvalid() async throws {
        let client = try XCTUnwrap(self.client)
        let table = "dupes_\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await client.admin.createTable(name: table, schema: "public", columns: [PostgresColumnDefinition(name: "code", dataType: "integer")])
        _ = try await client.bulk.insert(into: table, schema: "public", columns: ["code"], values: [[.bind(1)], [.bind(1)]])
        do {
            _ = try await client.indexes.createAdvancedIndex(name: "\(table)_code", table: table, schema: "public",
                                                             columns: [PostgresIndexColumn(name: "code")], unique: true, concurrently: true)
            XCTFail("the unique index should not build over duplicates")
        } catch {}
        let index = try await client.metadata.listIndexes(schema: "public", table: table).first { $0.name == "\(table)_code" }
        XCTAssertEqual(index?.isValid, false)
        _ = try await client.admin.dropTable(name: table, schema: "public")
    }
}

