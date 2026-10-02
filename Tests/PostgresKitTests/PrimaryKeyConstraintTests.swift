import XCTest
import Logging
@testable import PostgresKit

final class PrimaryKeyConstraintTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "PrimaryKeyConstraintTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    private func uniqueName(_ prefix: String = "pk") -> String {
        "\(prefix)_\(UInt32.random(in: 0..<UInt32.max))"
    }

    // MARK: - Single Column Primary Key

    func testAddPrimaryKeyToExistingColumn() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id"),
            .integer(name: "code", nullable: false),
            .text(name: "name", nullable: false)
        ])

        _ = try await client.constraints.addPrimaryKey(table: table, column: "code", constraintName: "\(table)_pk")

        _ = try await client.bulk.insert(into: table, columns: ["code", "name"], values: [[100, "Item A"], [200, "Item B"]])

        // Verify data was inserted
        let rows = try await client.simpleQuery("SELECT code FROM \(table) ORDER BY code")
        var codes: [Int] = []
        for try await code in rows.decode(Int.self) { codes.append(code) }
        XCTAssertEqual(codes, [100, 200])
    }

    func testPrimaryKeyViolation() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id"),
            .integer(name: "code", nullable: false),
            .text(name: "name", nullable: false)
        ])
        _ = try await client.constraints.addPrimaryKey(table: table, column: "code", constraintName: "\(table)_pk")

        _ = try await client.bulk.insert(into: table, columns: ["code", "name"], values: [[100, "Item A"]])

        do {
            _ = try await client.bulk.insert(into: table, columns: ["code", "name"], values: [[100, "Item C"]])
            XCTFail("Expected primary key violation")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isUniqueViolation, "Should be a unique violation error")
        }
    }

    func testBigSerialPrimaryKey() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .text(name: "name", nullable: false)
        ])

        _ = try await client.bulk.insert(into: table, columns: ["name"], values: [["First"], ["Second"]])

        let rows = try await client.simpleQuery("SELECT id FROM \(table) ORDER BY id")
        var ids: [Int] = []
        for try await id in rows.decode(Int.self) { ids.append(id) }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0] + 1, ids[1], "Serial IDs should be sequential")
    }

    // MARK: - Composite Primary Key

    func testCompositePrimaryKey() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .text(name: "department", nullable: false),
            .integer(name: "employee_id", nullable: false),
            .varchar(name: "name", length: 100, nullable: false)
        ])

        _ = try await client.constraints.addPrimaryKey(table: table, column: "department", constraintName: "\(table)_pk")

        _ = try await client.bulk.insert(into: table, columns: ["department", "employee_id", "name"], values: [
            ["IT", 1, "John Doe"],
            ["HR", 2, "Jane Smith"]
        ])

        // Same department should violate PK
        do {
            _ = try await client.bulk.insert(into: table, columns: ["department", "employee_id", "name"], values: [["IT", 3, "Another"]])
            XCTFail("Expected composite primary key violation")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isUniqueViolation)
        }
    }

    // MARK: - Primary Key with Different Data Types

    func testUUIDPrimaryKey() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .uuid(name: "id", nullable: false),
            .text(name: "name", nullable: false)
        ])
        _ = try await client.constraints.addPrimaryKey(table: table, column: "id", constraintName: "\(table)_pk")

        let id = UUID()
        _ = try await client.bulk.insert(into: table, columns: ["id", "name"], values: [[id, "Test"]])

        // Same UUID should violate
        do {
            _ = try await client.bulk.insert(into: table, columns: ["id", "name"], values: [[id, "Duplicate"]])
            XCTFail("Expected UUID primary key violation")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isUniqueViolation)
        }
    }

    func testTextPrimaryKey() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .varchar(name: "code", length: 20, nullable: false),
            .text(name: "description")
        ])
        _ = try await client.constraints.addPrimaryKey(table: table, column: "code", constraintName: "\(table)_pk")

        _ = try await client.bulk.insert(into: table, columns: ["code", "description"], values: [["ABC", "First"]])

        do {
            _ = try await client.bulk.insert(into: table, columns: ["code", "description"], values: [["ABC", "Duplicate"]])
            XCTFail("Expected text primary key violation")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isUniqueViolation)
        }
    }
}
