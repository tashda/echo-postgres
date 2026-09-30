import XCTest
import Logging
@testable import PostgresKit

/// Integration tests for PostgresError with real database operations.
/// Tests unique violations, FK violations, syntax errors, and the
/// executeWithEnhancedError API against a live database.
final class ErrorIntegrationTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "ErrorIntegrationTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    private func uniqueName(_ prefix: String = "err") -> String {
        "\(prefix)_\(UInt32.random(in: 0..<UInt32.max))"
    }

    // MARK: - Unique Violation via Real INSERT

    /// queryResult uses PostgresNIO's future-based API, whose errors used to lose their SQLSTATE.
    func testQueryResultErrorsKeepTheirSQLState() async throws {
        let table = uniqueName("qr")
        _ = try await client.simpleQueryResult("CREATE TABLE \(table) (id int PRIMARY KEY)")
        defer { Task { [client = self.client!] in _ = try? await client.simpleQueryResult("DROP TABLE IF EXISTS \(table)") } }
        _ = try await client.simpleQueryResult("INSERT INTO \(table) VALUES (1)")
        do {
            _ = try await client.withConnection { try await $0.queryResult("INSERT INTO \(table) VALUES (1)") }
            XCTFail("duplicate key")
        } catch let error as PostgresError {
            XCTAssertEqual(error.sqlState, "23505")
            XCTAssertTrue(error.isUniqueViolation)
            XCTAssertTrue(error.message.contains("\(table)_pkey"), error.message)
        }
    }

    func testUniqueViolationThrowsPostgresError() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .text(name: "email", nullable: false)
        ])
        _ = try await client.constraints.addUniqueConstraint(table: table, columns: ["email"], constraintName: "\(table)_uk")

        _ = try await client.bulk.insert(into: table, columns: ["email"], values: [["test@example.com"]])

        do {
            _ = try await client.bulk.insert(into: table, columns: ["email"], values: [["test@example.com"]])
            XCTFail("Expected error for duplicate email")
        } catch {
            XCTAssertTrue(error is PostgresError, "Expected PostgresError, got \(type(of: error))")
            if let pgError = error as? PostgresError {
                XCTAssertTrue(pgError.isUniqueViolation, "Should detect unique violation")
                let debugInfo = pgError.withDebugging()
                XCTAssertFalse(debugInfo.description.isEmpty)
            }
        }
    }

    // MARK: - Foreign Key Violation via Real INSERT

    func testForeignKeyViolationThrowsPostgresError() async throws {
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

        do {
            _ = try await client.bulk.insert(into: child, columns: ["parent_id", "value"], values: [[999, "Orphan"]])
            XCTFail("Expected foreign key violation")
        } catch {
            XCTAssertTrue(error is PostgresError, "Expected PostgresError, got \(type(of: error))")
            if let pgError = error as? PostgresError {
                XCTAssertTrue(pgError.isForeignKeyViolation, "Should detect FK violation")
            }
        }
    }

    // MARK: - Syntax Error

    func testSyntaxErrorThrowsError() async throws {
        // simpleQuery passes through PSQLError from the wire layer (not wrapped in PostgresError)
        do {
            _ = try await client.simpleQuery("SELEKT 1")
            XCTFail("Expected syntax error")
        } catch {
            // Verify an error was thrown — simpleQuery throws PSQLError, not PostgresError
            XCTAssertFalse(error is PostgresError && (error as! PostgresError).isConstraintViolation)
        }
    }

    // MARK: - Nonexistent Table Error

    func testNonexistentTableError() async throws {
        let fakeName = uniqueName("nonexistent")
        do {
            _ = try await client.simpleQuery("SELECT * FROM \(fakeName)")
            XCTFail("Expected error for nonexistent table")
        } catch {
            // Verify an error was thrown — simpleQuery throws PSQLError directly
        }
    }

    // MARK: - executeWithEnhancedError API

    func testExecuteWithEnhancedErrorUniqueViolation() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .text(name: "name", nullable: false),
            .text(name: "email", nullable: false)
        ])
        _ = try await client.constraints.addUniqueConstraint(table: table, columns: ["email"], constraintName: "\(table)_uk")

        _ = try await client.bulk.insert(into: table, columns: ["name", "email"], values: [["John", "john@example.com"]])

        let result = await PostgresClient.executeWithEnhancedError {
            try await client.bulk.insert(
                into: table,
                columns: ["name", "email"],
                values: [["Jane", "john@example.com"]]
            )
        }

        switch result {
        case .success:
            XCTFail("Expected error for duplicate email")
        case .failure(let error):
            XCTAssertTrue(error.isUniqueViolation || error.message.contains("uk_"), "Should detect unique violation")
            let debugInfo = error.withDebugging()
            XCTAssertFalse(debugInfo.description.isEmpty)
        }
    }

    func testExecuteWithEnhancedErrorForeignKeyViolation() async throws {
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

        let result = await PostgresClient.executeWithEnhancedError {
            try await client.bulk.insert(into: child, columns: ["parent_id", "value"], values: [[999, "Orphan"]])
        }

        switch result {
        case .success:
            XCTFail("Expected foreign key violation")
        case .failure(let error):
            XCTAssertTrue(error.isForeignKeyViolation || error.message.contains("fk_"), "Should detect FK violation")
        }
    }

    // MARK: - PSQLError localizedDescription

    func testPSQLErrorLocalizedDescriptionContainsServerMessage() async throws {
        // simpleQuery throws raw PSQLError. Verify that our @retroactive
        // LocalizedError conformance makes localizedDescription readable.
        do {
            _ = try await client.simpleQuery("SELECT * FROM nonexistent_table_\(uniqueName())")
            XCTFail("Expected error for nonexistent table")
        } catch let error as PSQLError {
            let description = error.localizedDescription
            // Should contain the actual Postgres message, not "PSQLError error 1"
            XCTAssertFalse(description.contains("error 1"),
                           "localizedDescription should not be the generic 'error 1' form, got: \(description)")
            XCTAssertTrue(description.contains("does not exist") || description.contains("relation"),
                          "localizedDescription should contain the server error message, got: \(description)")
        } catch {
            // If it's already wrapped as PostgresError, that's also fine
            let description = error.localizedDescription
            XCTAssertFalse(description.contains("error 1"),
                           "localizedDescription should not be the generic 'error 1' form, got: \(description)")
        }
    }

    // MARK: - Error Conversion from Traditional catch

    func testTraditionalCatchConvertsToPostgresError() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .text(name: "email", nullable: false)
        ])
        _ = try await client.constraints.addUniqueConstraint(table: table, columns: ["email"], constraintName: "\(table)_uk")

        _ = try await client.bulk.insert(into: table, columns: ["email"], values: [["bob@example.com"]])

        do {
            _ = try await client.bulk.insert(into: table, columns: ["email"], values: [["bob@example.com"]])
            XCTFail("Expected duplicate error")
        } catch {
            let postgresError: PostgresError
            if let existingError = error as? PostgresError {
                postgresError = existingError
            } else if let psqlError = error as? PSQLError {
                postgresError = PostgresError(from: psqlError)
            } else {
                postgresError = PostgresError(message: error.localizedDescription)
            }

            XCTAssertTrue(postgresError.isUniqueViolation || postgresError.message.lowercased().contains("duplicate"))
        }
    }
}
