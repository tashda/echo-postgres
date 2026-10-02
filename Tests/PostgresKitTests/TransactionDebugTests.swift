import XCTest
import Logging
@testable import PostgresKit

final class TransactionDebugTests: PostgresKitTestCase {

    private var client: PostgresKit.PostgresClient!
    private var testLogger: Logger!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else {
            throw XCTSkip("POSTGRES_HOST not set; skipping integration test")
        }
        testLogger = Logger(label: "postgres.wire.tests")

        let config = PostgresConfiguration(
            host: TestEnv.host,
            port: TestEnv.port,
            database: TestEnv.database,
            username: TestEnv.username,
            password: TestEnv.password,
            useTLS: TestEnv.useTLS,
            applicationName: "TransactionDebugTests"
        )

        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: testLogger)
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    // Test to understand the behavior of temporary tables
    func testTemporaryTableBehavior() async throws {
        logger.info("Testing Temporary Table Behavior")

        let log = self.logger
        let result = try await client.withConnection { conn in
            // Create temporary table and test its behavior
            _ = try await conn.createTable(
                name: "debug_tx",
                columns: [.serial(name: "id", primaryKey: true), .text(name: "value")],
                temporary: true
            )

            // Insert a row and check immediate result
            log.info("About to insert first row")
            _ = try await conn.insert(into: "debug_tx", columns: ["value"], values: [["test1"]])
            log.info("First insert completed")

            // Count immediately
            let countRows1 = try await conn.simpleQuery("SELECT COUNT(*)::text FROM debug_tx")
            var count1 = 0
            for try await countStr in countRows1.decode(String.self) {
                if let intVal = Int(countStr) {
                    count1 = intVal
                }
                break
            }
            log.info("After 1 insert: COUNT = \(count1)")

            // Verify the actual data exists
            let dataRows1 = try await conn.simpleQuery("SELECT id, value FROM debug_tx")
            var rowCount1 = 0
            for try await (id, value) in dataRows1.decode((Int32, String).self) {
                rowCount1 += 1
                log.info("Found row: id=\(id), value='\(value)'")
            }
            log.info("Actual rows found: \(rowCount1)")

            // Insert another row
            log.info("About to insert second row")
            _ = try await conn.insert(into: "debug_tx", columns: ["value"], values: [["test2"]])
            log.info("Second insert completed")

            // Count again
            let countRows2 = try await conn.simpleQuery("SELECT COUNT(*)::text FROM debug_tx")
            var count2 = 0
            for try await countStr in countRows2.decode(String.self) {
                if let intVal = Int(countStr) {
                    count2 = intVal
                }
                break
            }
            log.info("After 2 inserts: COUNT = \(count2)")

            // Verify the actual data exists again
            let dataRows2 = try await conn.simpleQuery("SELECT id, value FROM debug_tx")
            var rowCount2 = 0
            for try await (id, value) in dataRows2.decode((Int32, String).self) {
                rowCount2 += 1
                log.info("Found row: id=\(id), value='\(value)'")
            }
            log.info("Actual rows found after second insert: \(rowCount2)")

            return Int32(count2)
        }

        XCTAssertEqual(result, 2)
        logger.info("Temporary table behavior test completed successfully")
    }

    func testTransactionIsolation() async throws {
        logger.info("Testing Transaction Isolation")

        let log = self.logger
        let result = try await client.withConnection { conn in
            // Start transaction
            _ = try await conn.beginTransaction()

            // Create table inside transaction
            _ = try await conn.createTable(
                name: "iso_tx",
                columns: [.serial(name: "id", primaryKey: true), .text(name: "value")],
                temporary: true
            )

            // Insert rows inside transaction
            _ = try await conn.insert(into: "iso_tx", columns: ["value"], values: [["iso1"], ["iso2"]])

            // Count inside transaction (before commit)
            let countBefore = try await conn.simpleQuery("SELECT COUNT(*)::text FROM iso_tx")
            var beforeCount = 0
            for try await countStr in countBefore.decode(String.self) {
                if let intVal = Int(countStr) {
                    beforeCount = intVal
                }
                break
            }
            log.info("Before COMMIT: COUNT = \(beforeCount)")

            // Commit transaction
            _ = try await conn.commit()

            // Count after commit
            let countAfter = try await conn.simpleQuery("SELECT COUNT(*)::text FROM iso_tx")
            var afterCount = 0
            for try await countStr in countAfter.decode(String.self) {
                if let intVal = Int(countStr) {
                    afterCount = intVal
                }
                break
            }
            log.info("After COMMIT: COUNT = \(afterCount)")

            return Int32(afterCount)
        }

        XCTAssertEqual(result, 2)
        logger.info("Transaction isolation test completed successfully")
    }

    func testRollbackBehavior() async throws {
        logger.info("Testing Rollback Behavior")

        let log = self.logger
        let result = try await client.withConnection { conn in
            // Create table outside transaction so it persists after rollback
            _ = try await conn.createTable(
                name: "rollback_tx",
                columns: [.serial(name: "id", primaryKey: true), .text(name: "value")],
                temporary: true
            )

            // Start transaction
            _ = try await conn.beginTransaction()

            // Insert row inside transaction
            _ = try await conn.insert(into: "rollback_tx", columns: ["value"], values: [["rollback_test"]])

            // Count inside transaction (before rollback)
            let countBefore = try await conn.simpleQuery("SELECT COUNT(*)::text FROM rollback_tx")
            var beforeCount = 0
            for try await countStr in countBefore.decode(String.self) {
                if let intVal = Int(countStr) {
                    beforeCount = intVal
                }
                break
            }
            log.info("Before ROLLBACK: COUNT = \(beforeCount)")

            // Rollback transaction
            _ = try await conn.rollback()

            // Count after rollback (table should still exist but be empty)
            let countAfter = try await conn.simpleQuery("SELECT COUNT(*)::text FROM rollback_tx")
            var afterCount = 0
            for try await countStr in countAfter.decode(String.self) {
                if let intVal = Int(countStr) {
                    afterCount = intVal
                }
                break
            }
            log.info("After ROLLBACK: COUNT = \(afterCount)")

            return Int32(afterCount)
        }

        XCTAssertEqual(result, 0)
        logger.info("Rollback test completed successfully")
    }
}
