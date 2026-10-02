import XCTest
import Logging
@testable import PostgresKit

final class UniqueConstraintTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "UniqueConstraintTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    private func uniqueName(_ prefix: String = "uq") -> String {
        "\(prefix)_\(UInt32.random(in: 0..<UInt32.max))"
    }

    // MARK: - Single Column Unique

    func testUniqueConstraintOnVarchar() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .varchar(name: "username", length: 50, nullable: false)
        ])
        _ = try await client.constraints.addUniqueConstraint(table: table, columns: ["username"], constraintName: "\(table)_uk")

        _ = try await client.bulk.insert(into: table, columns: ["username"], values: [["alice"]])

        do {
            _ = try await client.bulk.insert(into: table, columns: ["username"], values: [["alice"]])
            XCTFail("Expected unique constraint violation")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isUniqueViolation)
        }
    }

    func testUniqueConstraintOnUUID() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .uuid(name: "external_id", nullable: false)
        ])
        _ = try await client.constraints.addUniqueConstraint(table: table, columns: ["external_id"], constraintName: "\(table)_uk")

        let uuid = UUID()
        _ = try await client.bulk.insert(into: table, columns: ["external_id"], values: [[uuid]])

        do {
            _ = try await client.bulk.insert(into: table, columns: ["external_id"], values: [[uuid]])
            XCTFail("Expected unique constraint violation on UUID")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isUniqueViolation)
        }
    }

    func testUniqueConstraintOnEmail() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .varchar(name: "email", length: 255, nullable: false)
        ])
        _ = try await client.constraints.addUniqueConstraint(table: table, columns: ["email"], constraintName: "\(table)_uk")

        _ = try await client.bulk.insert(into: table, columns: ["email"], values: [["user@example.com"]])

        do {
            _ = try await client.bulk.insert(into: table, columns: ["email"], values: [["user@example.com"]])
            XCTFail("Expected unique constraint violation on email")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isUniqueViolation)
        }
    }

    // MARK: - Composite Unique

    func testCompositeUniqueConstraint() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .text(name: "first_name", nullable: false),
            .text(name: "last_name", nullable: false),
            .date(name: "birth_date", nullable: false)
        ])
        _ = try await client.constraints.addUniqueConstraint(
            table: table, columns: ["first_name", "last_name"],
            constraintName: "\(table)_name_uk"
        )

        _ = try await client.bulk.insert(into: table, columns: ["first_name", "last_name", "birth_date"],
                                     values: [["John", "Doe", Date(timeIntervalSince1970: 0)]])

        // Same first+last name should violate
        do {
            _ = try await client.bulk.insert(into: table, columns: ["first_name", "last_name", "birth_date"],
                                         values: [["John", "Doe", Date()]])
            XCTFail("Expected composite unique violation")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isUniqueViolation)
        }

        // Different last name should succeed
        _ = try await client.bulk.insert(into: table, columns: ["first_name", "last_name", "birth_date"],
                                     values: [["John", "Smith", Date(timeIntervalSince1970: 0)]])
    }

    // MARK: - NULL Handling

    func testUniqueConstraintAllowsMultipleNulls() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .varchar(name: "code", length: 50) // nullable
        ])
        _ = try await client.constraints.addUniqueConstraint(table: table, columns: ["code"], constraintName: "\(table)_uk")

        // PostgreSQL allows multiple NULLs in unique columns
        _ = try await client.bulk.insert(into: table, columns: ["code"], values: [[nil], [nil]])

        let rows = try await client.simpleQuery("SELECT count(*) FROM \(table) WHERE code IS NULL")
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertEqual(count, 2, "Multiple NULLs should be allowed in unique column")
    }

    // MARK: - Unique with Network Types

    func testUniqueConstraintOnMacaddr() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .macaddr(name: "mac", nullable: false)
        ])
        _ = try await client.constraints.addUniqueConstraint(table: table, columns: ["mac"], constraintName: "\(table)_uk")

        _ = try await client.bulk.insert(into: table, columns: ["mac"], values: [[MACAddress(string: "00:11:22:33:44:55")]])

        do {
            _ = try await client.bulk.insert(into: table, columns: ["mac"], values: [[MACAddress(string: "00:11:22:33:44:55")]])
            XCTFail("Expected unique constraint violation on macaddr")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isUniqueViolation)
        }
    }

    func testUniqueConstraintOnInet() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .inet(name: "ip", nullable: false)
        ])
        _ = try await client.constraints.addUniqueConstraint(table: table, columns: ["ip"], constraintName: "\(table)_uk")

        _ = try await client.bulk.insert(into: table, columns: ["ip"], values: [[.inet("192.168.1.1")], [.inet("10.0.0.1")]])

        do {
            _ = try await client.bulk.insert(into: table, columns: ["ip"], values: [[.inet("192.168.1.1")]])
            XCTFail("Expected unique constraint violation on inet")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isUniqueViolation)
        }
    }
}
