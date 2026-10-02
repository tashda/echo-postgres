import XCTest
import Logging
@testable import PostgresKit

final class ForeignKeyConstraintTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "ForeignKeyConstraintTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    private func uniqueName(_ prefix: String = "fk") -> String {
        "\(prefix)_\(UInt32.random(in: 0..<UInt32.max))"
    }

    // MARK: - Basic Foreign Key

    func testForeignKeyEnforcesReferentialIntegrity() async throws {
        let parent = uniqueName("parent")
        let child = uniqueName("child")
        defer { Task { [client = self.client!] in
            _ = try? await client.admin.dropTable(name: child, ifExists: true)
            _ = try? await client.admin.dropTable(name: parent, ifExists: true)
        }}

        _ = try await client.admin.createTable(name: parent, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .text(name: "name", nullable: false)
        ])
        _ = try await client.admin.createTable(name: child, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .bigInt(name: "parent_id", nullable: false),
            .text(name: "value")
        ])
        _ = try await client.constraints.addForeignKey(
            table: child, column: "parent_id",
            referencesTable: parent, referencesColumn: "id",
            constraintName: "\(child)_fk"
        )

        _ = try await client.bulk.insert(into: parent, columns: ["name"], values: [["Parent 1"]])
        let rows = try await client.simpleQuery("SELECT id FROM \(parent) LIMIT 1")
        var parentId: Int?
        for try await id in rows.decode(Int.self) { parentId = id }

        // Valid FK reference
        _ = try await client.bulk.insert(into: child, columns: ["parent_id", "value"], values: [[parentId!, "Child 1"]])

        // Invalid FK reference
        do {
            _ = try await client.bulk.insert(into: child, columns: ["parent_id", "value"], values: [[99999, "Orphan"]])
            XCTFail("Expected foreign key violation")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isForeignKeyViolation, "Should be a foreign key violation")
        }
    }

    // MARK: - ON DELETE CASCADE

    func testForeignKeyCascadeDelete() async throws {
        let parent = uniqueName("parent")
        let child = uniqueName("child")
        defer { Task { [client = self.client!] in
            _ = try? await client.admin.dropTable(name: child, ifExists: true)
            _ = try? await client.admin.dropTable(name: parent, ifExists: true)
        }}

        _ = try await client.admin.createTable(name: parent, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .text(name: "name", nullable: false)
        ])
        _ = try await client.admin.createTable(name: child, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .bigInt(name: "parent_id", nullable: false),
            .text(name: "value")
        ])
        _ = try await client.constraints.addForeignKey(
            table: child, column: "parent_id",
            referencesTable: parent, referencesColumn: "id",
            constraintName: "\(child)_cascade_fk",
            onDelete: .cascade
        )

        _ = try await client.bulk.insert(into: parent, columns: ["name"], values: [["To Delete"]])
        let rows = try await client.simpleQuery("SELECT id FROM \(parent) LIMIT 1")
        var parentId: Int?
        for try await id in rows.decode(Int.self) { parentId = id }

        _ = try await client.bulk.insert(into: child, columns: ["parent_id", "value"], values: [
            [parentId!, "Child A"],
            [parentId!, "Child B"]
        ])

        // Verify children exist
        let beforeRows = try await client.simpleQuery("SELECT count(*) FROM \(child)")
        var beforeCount: Int64 = 0
        for try await c in beforeRows.decode(Int64.self) { beforeCount = c }
        XCTAssertEqual(beforeCount, 2)

        // Delete parent — children should cascade
        _ = try await client.bulk.delete(from: parent, whereClause: "id = \(parentId!)")

        let afterRows = try await client.simpleQuery("SELECT count(*) FROM \(child)")
        var afterCount: Int64 = 0
        for try await c in afterRows.decode(Int64.self) { afterCount = c }
        XCTAssertEqual(afterCount, 0, "Children should be cascade-deleted")
    }

    // MARK: - ON DELETE SET NULL

    func testForeignKeySetNull() async throws {
        let parent = uniqueName("parent")
        let child = uniqueName("child")
        defer { Task { [client = self.client!] in
            _ = try? await client.admin.dropTable(name: child, ifExists: true)
            _ = try? await client.admin.dropTable(name: parent, ifExists: true)
        }}

        _ = try await client.admin.createTable(name: parent, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .text(name: "name", nullable: false)
        ])
        _ = try await client.admin.createTable(name: child, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .bigInt(name: "parent_id"), // nullable for SET NULL
            .text(name: "value")
        ])
        _ = try await client.constraints.addForeignKey(
            table: child, column: "parent_id",
            referencesTable: parent, referencesColumn: "id",
            constraintName: "\(child)_setnull_fk",
            onDelete: .setNull
        )

        _ = try await client.bulk.insert(into: parent, columns: ["name"], values: [["To Delete"]])
        let rows = try await client.simpleQuery("SELECT id FROM \(parent) LIMIT 1")
        var parentId: Int?
        for try await id in rows.decode(Int.self) { parentId = id }

        _ = try await client.bulk.insert(into: child, columns: ["parent_id", "value"], values: [[parentId!, "Child"]])

        // Delete parent — child's parent_id should become NULL
        _ = try await client.bulk.delete(from: parent, whereClause: "id = \(parentId!)")

        let childRows = try await client.simpleQuery("SELECT parent_id FROM \(child)")
        var foundNull = false
        for try await pid in childRows.decode(Int?.self) {
            XCTAssertNil(pid, "parent_id should be NULL after SET NULL")
            foundNull = true
        }
        XCTAssertTrue(foundNull)
    }

    // MARK: - ON DELETE RESTRICT

    func testForeignKeyRestrictDelete() async throws {
        let parent = uniqueName("parent")
        let child = uniqueName("child")
        defer { Task { [client = self.client!] in
            _ = try? await client.admin.dropTable(name: child, ifExists: true)
            _ = try? await client.admin.dropTable(name: parent, ifExists: true)
        }}

        _ = try await client.admin.createTable(name: parent, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .text(name: "name", nullable: false)
        ])
        _ = try await client.admin.createTable(name: child, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .bigInt(name: "parent_id", nullable: false),
            .text(name: "value")
        ])
        _ = try await client.constraints.addForeignKey(
            table: child, column: "parent_id",
            referencesTable: parent, referencesColumn: "id",
            constraintName: "\(child)_restrict_fk",
            onDelete: .restrict
        )

        _ = try await client.bulk.insert(into: parent, columns: ["name"], values: [["Protected"]])
        let rows = try await client.simpleQuery("SELECT id FROM \(parent) LIMIT 1")
        var parentId: Int?
        for try await id in rows.decode(Int.self) { parentId = id }

        _ = try await client.bulk.insert(into: child, columns: ["parent_id", "value"], values: [[parentId!, "Child"]])

        // Deleting parent should fail due to FK constraint
        do {
            _ = try await client.bulk.delete(from: parent, whereClause: "id = \(parentId!)")
            XCTFail("Expected foreign key violation on RESTRICT delete")
        } catch {
            // The DELETE was correctly rejected — verify it's a FK violation if serverInfo is available
            let pgError = PostgresError.from(error)
            if pgError.sqlState != nil {
                XCTAssertTrue(pgError.isForeignKeyViolation, "Expected FK/restrict violation (23503 or 23001), got sqlState: \(pgError.sqlState ?? "nil")")
            }
        }
    }

    // MARK: - UUID Foreign Key

    func testForeignKeyWithUUID() async throws {
        let parent = uniqueName("parent")
        let child = uniqueName("child")
        defer { Task { [client = self.client!] in
            _ = try? await client.admin.dropTable(name: child, ifExists: true)
            _ = try? await client.admin.dropTable(name: parent, ifExists: true)
        }}

        _ = try await client.admin.createTable(name: parent, columns: [
            .uuid(name: "id", nullable: false),
            .text(name: "name", nullable: false)
        ])
        _ = try await client.constraints.addPrimaryKey(table: parent, column: "id", constraintName: "\(parent)_pk")

        _ = try await client.admin.createTable(name: child, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .uuid(name: "parent_uuid", nullable: false),
            .text(name: "value")
        ])
        _ = try await client.constraints.addForeignKey(
            table: child, column: "parent_uuid",
            referencesTable: parent, referencesColumn: "id",
            constraintName: "\(child)_uuid_fk",
            onDelete: .cascade
        )

        let parentUUID = UUID()
        _ = try await client.bulk.insert(into: parent, columns: ["id", "name"], values: [[parentUUID, "UUID Parent"]])
        _ = try await client.bulk.insert(into: child, columns: ["parent_uuid", "value"], values: [[parentUUID, "UUID Child"]])

        // Non-existent UUID should fail
        do {
            _ = try await client.bulk.insert(into: child, columns: ["parent_uuid", "value"], values: [[UUID(), "Orphan"]])
            XCTFail("Expected FK violation for non-existent UUID")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isForeignKeyViolation)
        }
    }
}
