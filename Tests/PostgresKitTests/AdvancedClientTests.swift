import XCTest
import Logging
@testable import PostgresKit

/// Tests client operations not covered elsewhere:
/// schema ops, enum types, column alters, DML helpers, advisory locks,
/// server config, cursor streaming, copyTable, createTableAs.
final class AdvancedClientTests: PostgresKitTestCase {
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
            applicationName: "AdvancedClientTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() async throws {
        client?.close()
    }

    private func uniqueName(_ prefix: String = "pgwire") -> String {
        "\(prefix)_\(UInt32.random(in: 0..<UInt32.max))"
    }

    // MARK: - Schema Operations

    func testCreateAndDropSchema() async throws {
        let schema = uniqueName("pgwire_schema")
        try await client.admin.createSchema(name: schema)

        let schemas = try await client.metadata.listSchemas()
        XCTAssertTrue(schemas.map(\.name).contains(schema), "Schema should appear after creation")

        try await client.admin.dropSchema(name: schema, cascade: true)

        let schemasAfter = try await client.metadata.listSchemas()
        XCTAssertFalse(schemasAfter.map(\.name).contains(schema), "Schema should be gone after drop")
    }

    func testCreateSchemaIfNotExists() async throws {
        let schema = uniqueName("pgwire_schema")
        try await client.admin.createSchema(name: schema, ifNotExists: true)
        // Calling again should not throw
        try await client.admin.createSchema(name: schema, ifNotExists: true)
        try await client.admin.dropSchema(name: schema, ifExists: true, cascade: true)
    }

    // MARK: - Enum Types

    func testCreateAndDropEnum() async throws {
        let typeName = uniqueName("pgwire_status")
        try await client.types.createEnum(name: typeName, values: ["active", "inactive", "pending"])

        // Use the enum in a table to confirm it works
        let table = uniqueName("pgwire_enum_t")
        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id"),
            PostgresColumnDefinition(name: "status", dataType: typeName)
        ])
        try await client.bulk.insert(into: table, columns: ["status"], values: [[.castLiteral("active", as: typeName)]])

        let rows = try await client.simpleQuery("SELECT status FROM \(table)")
        var values: [String] = []
        for try await v in rows.decode(String.self) { values.append(v) }
        XCTAssertEqual(values, ["active"])

        try await client.admin.dropTable(name: table, ifExists: true)
        try await client.types.dropEnum(name: typeName, ifExists: true, cascade: true)
    }

    func testAddEnumValue() async throws {
        let typeName = uniqueName("pgwire_color")
        try await client.types.createEnum(name: typeName, values: ["red", "green"])
        try await client.types.addEnumValue(type: typeName, value: "blue")

        let table = uniqueName("pgwire_color_t")
        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id"),
            PostgresColumnDefinition(name: "color", dataType: typeName)
        ])
        try await client.bulk.insert(into: table, columns: ["color"], values: [[.castLiteral("blue", as: typeName)]])

        let rows = try await client.simpleQuery("SELECT color FROM \(table)")
        var values: [String] = []
        for try await v in rows.decode(String.self) { values.append(v) }
        XCTAssertEqual(values, ["blue"])

        try await client.admin.dropTable(name: table, ifExists: true)
        try await client.types.dropEnum(name: typeName, ifExists: true, cascade: true)
    }

    func testRenameEnumValue() async throws {
        let typeName = uniqueName("pgwire_mood")
        try await client.types.createEnum(name: typeName, values: ["happy", "sad"])
        try await client.types.renameEnumValue(type: typeName, oldValue: "sad", newValue: "unhappy")

        let table = uniqueName("pgwire_mood_t")
        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id"),
            PostgresColumnDefinition(name: "mood", dataType: typeName)
        ])
        try await client.bulk.insert(into: table, columns: ["mood"], values: [[.castLiteral("unhappy", as: typeName)]])

        let rows = try await client.simpleQuery("SELECT mood FROM \(table)")
        var values: [String] = []
        for try await v in rows.decode(String.self) { values.append(v) }
        XCTAssertEqual(values, ["unhappy"])

        try await client.admin.dropTable(name: table, ifExists: true)
        try await client.types.dropEnum(name: typeName, ifExists: true, cascade: true)
    }

    // MARK: - Column Alterations

    func testAlterColumnDefault() async throws {
        let table = uniqueName("pgwire_altdef")
        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            .integer(name: "score")
        ])
        defer {
            Task.detached { [client, table] in
                _ = try? await client?.admin.dropTable(name: table, ifExists: true)
            }
        }

        // Set default
        try await client.admin.alterColumnDefault(table: table, column: "score", defaultValue: "42")
        let meta = try await client.metadata.listColumns(schema: "public", table: table)
        let scoreCol = meta.first { $0.name == "score" }
        XCTAssertNotNil(scoreCol?.defaultValue, "score should have a default value")

        // Remove default
        try await client.admin.alterColumnDefault(table: table, column: "score", defaultValue: nil)
        let meta2 = try await client.metadata.listColumns(schema: "public", table: table)
        let scoreCol2 = meta2.first { $0.name == "score" }
        XCTAssertNil(scoreCol2?.defaultValue, "score should have no default after DROP DEFAULT")
    }

    func testAlterColumnNullability() async throws {
        let table = uniqueName("pgwire_altnull")
        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            .text(name: "label")
        ])
        defer {
            Task.detached { [client, table] in
                _ = try? await client?.admin.dropTable(name: table, ifExists: true)
            }
        }

        // Add data first so NOT NULL constraint doesn't fail
        try await client.bulk.insert(into: table, columns: ["label"], values: [["hello"] as [Any]])

        // Make NOT NULL
        try await client.admin.alterColumnNullability(table: table, column: "label", nullable: false)
        let meta = try await client.metadata.listColumns(schema: "public", table: table)
        let col = meta.first { $0.name == "label" }
        XCTAssertEqual(col?.isNullable, false, "Column should be NOT NULL")

        // Make nullable again
        try await client.admin.alterColumnNullability(table: table, column: "label", nullable: true)
        let meta2 = try await client.metadata.listColumns(schema: "public", table: table)
        let col2 = meta2.first { $0.name == "label" }
        XCTAssertEqual(col2?.isNullable, true, "Column should be nullable again")
    }

    func testRenameColumn() async throws {
        let table = uniqueName("pgwire_rencol")
        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            .text(name: "old_name")
        ])
        defer {
            Task.detached { [client, table] in
                _ = try? await client?.admin.dropTable(name: table, ifExists: true)
            }
        }

        try await client.admin.renameColumn(table: table, oldName: "old_name", newName: "new_name")

        let cols = try await client.metadata.listColumns(schema: "public", table: table)
        let names = cols.map { $0.name }
        XCTAssertTrue(names.contains("new_name"), "Renamed column should appear")
        XCTAssertFalse(names.contains("old_name"), "Old column name should not appear")
    }

    // MARK: - DML Convenience Methods

    func testInsertUpdateDeleteTruncate() async throws {
        let table = uniqueName("pgwire_dml")
        try await client.admin.createTable(name: table, columns: [
            .integer(name: "id"),
            .text(name: "name"),
            .boolean(name: "active")
        ])
        defer {
            Task.detached { [client, table] in
                _ = try? await client?.admin.dropTable(name: table, ifExists: true)
            }
        }

        // INSERT
        try await client.bulk.insert(
            into: table,
            columns: ["id", "name", "active"],
            values: [
                [1, "Alice", true] as [Any],
                [2, "Bob", false] as [Any],
                [3, "Carol", true] as [Any]
            ]
        )

        let countAfterInsert = try await rowCount(table: table)
        XCTAssertEqual(countAfterInsert, 3)

        // UPDATE
        try await client.bulk.update(table: table, set: ["active": false], whereClause: "id = 1")
        let rows = try await client.simpleQuery("SELECT active FROM \(table) WHERE id = 1")
        var active: Bool?
        for try await v in rows.decode(Bool.self) { active = v; break }
        XCTAssertEqual(active, false)

        // DELETE
        try await client.bulk.delete(from: table, whereClause: "id = 3")
        let countAfterDelete = try await rowCount(table: table)
        XCTAssertEqual(countAfterDelete, 2)

        // TRUNCATE
        try await client.bulk.truncate(table: table)
        let countAfterTruncate = try await rowCount(table: table)
        XCTAssertEqual(countAfterTruncate, 0)
    }

    // MARK: - copyTable and createTableAs

    func testCopyTable() async throws {
        let src = uniqueName("pgwire_cpsrc")
        let dst = uniqueName("pgwire_cpdst")
        try await client.admin.createTable(name: src, columns: [
            .integer(name: "id"),
            .text(name: "val")
        ])
        try await client.bulk.insert(into: src, columns: ["id", "val"], values: [
            [1, "a"] as [Any],
            [2, "b"] as [Any],
            [3, "c"] as [Any]
        ])
        try await client.admin.createTable(name: dst, columns: [
            .integer(name: "id"),
            .text(name: "val")
        ])
        defer {
            Task.detached { [client, src, dst] in
                _ = try? await client?.admin.dropTable(name: src, ifExists: true)
                _ = try? await client?.admin.dropTable(name: dst, ifExists: true)
            }
        }

        try await client.admin.copyTable(from: src, to: dst)
        let copyCount = try await rowCount(table: dst)
        XCTAssertEqual(copyCount, 3)
    }

    func testCreateTableAs() async throws {
        let src = uniqueName("pgwire_ctas_src")
        let dst = uniqueName("pgwire_ctas_dst")
        try await client.admin.createTable(name: src, columns: [
            .integer(name: "id"),
            .text(name: "name")
        ])
        try await client.bulk.insert(into: src, columns: ["id", "name"], values: [
            [1, "Alice"] as [Any],
            [2, "Bob"] as [Any]
        ])
        defer {
            Task.detached { [client, src, dst] in
                _ = try? await client?.admin.dropTable(name: dst, ifExists: true)
                _ = try? await client?.admin.dropTable(name: src, ifExists: true)
            }
        }

        try await client.admin.createTableAs(name: dst, selectQuery: "SELECT * FROM \(src)")
        let ctasCount = try await rowCount(table: dst)
        XCTAssertEqual(ctasCount, 2)
    }

    // MARK: - Advisory Locks

    // TODO: uncomment when tryAcquireAdvisoryLock/releaseAdvisoryLock APIs are implemented on PostgresAdminClient
//    func testTryAdvisoryLock_AndUnlock() async throws {
//        let key: Int64 = 987654321
//        // Unlock first in case a previous test left it locked
//        _ = try? await client.session.releaseAdvisoryLock(key: key)
//
//        let acquired = try await client.session.tryAcquireAdvisoryLock(key: key)
//        XCTAssertTrue(acquired, "Should be able to acquire advisory lock")
//
//        let released = try await client.session.releaseAdvisoryLock(key: key)
//        XCTAssertTrue(released, "Should release the advisory lock")
//    }
//
//    func testTryAdvisoryLock_SameKey_TwiceOnSameSession() async throws {
//        // PostgreSQL advisory locks are session-level; same session can acquire the same lock multiple times
//        let key: Int64 = 111222333
//        _ = try? await client.session.releaseAdvisoryLock(key: key)
//
//        let first = try await client.session.tryAcquireAdvisoryLock(key: key)
//        XCTAssertTrue(first)
//
//        // In PostgreSQL, session-level advisory locks are re-entrant from the same session
//        let second = try await client.session.tryAcquireAdvisoryLock(key: key)
//        XCTAssertTrue(second, "Re-entrant advisory lock on same session should succeed")
//
//        // Unlock needs to be called once per acquire
//        _ = try? await client.session.releaseAdvisoryLock(key: key)
//        _ = try? await client.session.releaseAdvisoryLock(key: key)
//    }

    // MARK: - Server Configuration

    func testSetAndResetConfiguration() async throws {
        let originalVal = try await client.serverConfig.show( "work_mem") ?? ""

        try await client.serverConfig.set( "work_mem", value: "16MB")

        let currentVal = try await client.serverConfig.show( "work_mem") ?? ""
        XCTAssertFalse(currentVal.isEmpty, "work_mem should be set")

        try await client.serverConfig.resetConfiguration(parameter: "work_mem")
        let restoredVal = try await client.serverConfig.show( "work_mem") ?? ""
        XCTAssertEqual(restoredVal, originalVal, "work_mem should be restored to its original value")
    }

    // MARK: - Cursor Streaming

    // MARK: - Helpers

    private func rowCount(table: String) async throws -> Int {
        let rows = try await client.simpleQuery("SELECT COUNT(*)::text FROM \(table)")
        var countStr = ""
        for try await s in rows.decode(String.self) { countStr = s; break }
        return Int(countStr) ?? 0
    }
}
