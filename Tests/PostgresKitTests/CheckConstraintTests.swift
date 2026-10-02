import XCTest
import Logging
@testable import PostgresKit

private struct ConfigJSON: JSONBEncodable {
    let theme: String
}

final class CheckConstraintTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "CheckConstraintTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    private func uniqueName(_ prefix: String = "ck") -> String {
        "\(prefix)_\(UInt32.random(in: 0..<UInt32.max))"
    }

    // MARK: - Numeric Range Check

    func testCheckConstraintNumericRange() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .integer(name: "age", nullable: false)
        ])
        _ = try await client.constraints.addCheckConstraint(
            table: table, condition: "age >= 18 AND age <= 120",
            constraintName: "\(table)_age"
        )

        // Valid
        _ = try await client.bulk.insert(into: table, columns: ["age"], values: [[25], [18], [120]])

        // Too low
        do {
            _ = try await client.bulk.insert(into: table, columns: ["age"], values: [[17]])
            XCTFail("Expected check constraint violation for age < 18")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isConstraintViolation)
        }

        // Too high
        do {
            _ = try await client.bulk.insert(into: table, columns: ["age"], values: [[121]])
            XCTFail("Expected check constraint violation for age > 120")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isConstraintViolation)
        }
    }

    // MARK: - Positive Value Check

    func testCheckConstraintPositiveDecimal() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .decimal(name: "salary", precision: 10, scale: 2, nullable: false)
        ])
        _ = try await client.constraints.addCheckConstraint(
            table: table, condition: "salary > 0",
            constraintName: "\(table)_salary"
        )

        _ = try await client.bulk.insert(into: table, columns: ["salary"], values: [[50000.00]])

        do {
            _ = try await client.bulk.insert(into: table, columns: ["salary"], values: [[-1000.00]])
            XCTFail("Expected check constraint violation for negative salary")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isConstraintViolation)
        }

        do {
            _ = try await client.bulk.insert(into: table, columns: ["salary"], values: [[0.00]])
            XCTFail("Expected check constraint violation for zero salary")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isConstraintViolation)
        }
    }

    // MARK: - String Length Check

    func testCheckConstraintStringLength() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .varchar(name: "username", length: 50, nullable: false)
        ])
        _ = try await client.constraints.addCheckConstraint(
            table: table, condition: "LENGTH(username) >= 3",
            constraintName: "\(table)_len"
        )

        _ = try await client.bulk.insert(into: table, columns: ["username"], values: [["alice"]])

        do {
            _ = try await client.bulk.insert(into: table, columns: ["username"], values: [["ab"]])
            XCTFail("Expected check constraint violation for short username")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isConstraintViolation)
        }
    }

    // MARK: - Regex Pattern Check

    func testCheckConstraintEmailPattern() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .varchar(name: "email", length: 255, nullable: false)
        ])
        _ = try await client.constraints.addCheckConstraint(
            table: table,
            condition: "email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$'",
            constraintName: "\(table)_email"
        )

        _ = try await client.bulk.insert(into: table, columns: ["email"], values: [["user@example.com"]])

        do {
            _ = try await client.bulk.insert(into: table, columns: ["email"], values: [["invalid-email"]])
            XCTFail("Expected check constraint violation for invalid email")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isConstraintViolation)
        }
    }

    // MARK: - Enum-like Status Check

    func testCheckConstraintStatusValues() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .text(name: "status", nullable: false)
        ])
        _ = try await client.constraints.addCheckConstraint(
            table: table,
            condition: "status IN ('active', 'inactive', 'pending', 'suspended')",
            constraintName: "\(table)_status"
        )

        _ = try await client.bulk.insert(into: table, columns: ["status"], values: [["active"], ["pending"]])

        do {
            _ = try await client.bulk.insert(into: table, columns: ["status"], values: [["invalid"]])
            XCTFail("Expected check constraint violation for invalid status")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isConstraintViolation)
        }
    }

    // MARK: - JSONB Type Check

    func testCheckConstraintJSONBType() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .jsonb(name: "config")
        ])
        _ = try await client.constraints.addCheckConstraint(
            table: table,
            condition: "jsonb_typeof(config) IN ('object', 'null')",
            constraintName: "\(table)_jsonb"
        )

        // Valid: JSON object
        _ = try await client.bulk.insert(into: table, columns: ["config"], values: [[ConfigJSON(theme: "dark")]])

        // Invalid: JSON array (not an object)
        do {
            _ = try await client.bulk.insert(into: table, columns: ["config"], values: [[.jsonbLiteral("[1,2,3]")]])
            XCTFail("Expected check constraint violation for non-object JSON")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isConstraintViolation)
        }
    }

    // MARK: - Date Logic Check

    func testCheckConstraintDateOrdering() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .date(name: "start_date", nullable: false),
            .date(name: "end_date", nullable: false)
        ])
        _ = try await client.constraints.addCheckConstraint(
            table: table, condition: "start_date < end_date",
            constraintName: "\(table)_dates"
        )

        // Valid: start before end
        _ = try await client.bulk.insert(into: table, columns: ["start_date", "end_date"],
                                     values: [[Date(timeIntervalSince1970: 0), Date()]])

        // Invalid: start after end
        do {
            _ = try await client.bulk.insert(into: table, columns: ["start_date", "end_date"],
                                         values: [[Date(), Date(timeIntervalSince1970: 0)]])
            XCTFail("Expected check constraint violation for date ordering")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isConstraintViolation)
        }
    }

    // MARK: - Boolean Logic Check

    func testCheckConstraintBooleanLogic() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .boolean(name: "is_active", nullable: false),
            .date(name: "termination_date")
        ])
        _ = try await client.constraints.addCheckConstraint(
            table: table,
            condition: "(is_active AND termination_date IS NULL) OR (NOT is_active AND termination_date IS NOT NULL)",
            constraintName: "\(table)_logic"
        )

        // Valid: active with no termination
        _ = try await client.bulk.insert(into: table, columns: ["is_active", "termination_date"], values: [[true, nil]])

        // Valid: inactive with termination date
        _ = try await client.bulk.insert(into: table, columns: ["is_active", "termination_date"], values: [[false, .currentDate]])

        // Invalid: active WITH termination date
        do {
            _ = try await client.bulk.insert(into: table, columns: ["is_active", "termination_date"], values: [[true, .currentDate]])
            XCTFail("Expected check constraint violation for active with termination")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isConstraintViolation)
        }

        // Invalid: inactive WITHOUT termination date
        do {
            _ = try await client.bulk.insert(into: table, columns: ["is_active", "termination_date"], values: [[false, nil]])
            XCTFail("Expected check constraint violation for inactive without termination")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isConstraintViolation)
        }
    }

    // MARK: - Complex Multi-column Check

    func testCheckConstraintEmployeeCodeFormat() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        _ = try await client.admin.createTable(name: table, columns: [
            .bigSerial(name: "id", primaryKey: true),
            .varchar(name: "code", length: 20, nullable: false),
            .integer(name: "level", nullable: false),
            .decimal(name: "salary", precision: 10, scale: 2, nullable: false)
        ])
        _ = try await client.constraints.addCheckConstraint(
            table: table,
            condition: "LENGTH(code) = 10 AND code ~ '^[A-Z]{2}[0-9]{8}$'",
            constraintName: "\(table)_code_fmt"
        )
        _ = try await client.constraints.addCheckConstraint(
            table: table, condition: "level BETWEEN 1 AND 10",
            constraintName: "\(table)_level"
        )
        _ = try await client.constraints.addCheckConstraint(
            table: table, condition: "salary >= 30000.00",
            constraintName: "\(table)_min_salary"
        )

        // Valid
        _ = try await client.bulk.insert(into: table, columns: ["code", "level", "salary"],
                                     values: [["EN12345678", 5, 75000.00]])

        // Invalid code format
        do {
            _ = try await client.bulk.insert(into: table, columns: ["code", "level", "salary"],
                                         values: [["INVALID", 5, 60000.00]])
            XCTFail("Expected check constraint violation for code format")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isConstraintViolation)
        }

        // Invalid level
        do {
            _ = try await client.bulk.insert(into: table, columns: ["code", "level", "salary"],
                                         values: [["AB12345678", 11, 60000.00]])
            XCTFail("Expected check constraint violation for level")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isConstraintViolation)
        }

        // Invalid salary
        do {
            _ = try await client.bulk.insert(into: table, columns: ["code", "level", "salary"],
                                         values: [["CD12345678", 5, 29999.99]])
            XCTFail("Expected check constraint violation for min salary")
        } catch {
            let pgError = PostgresError.from(error)
            XCTAssertTrue(pgError.isConstraintViolation)
        }
    }
}
