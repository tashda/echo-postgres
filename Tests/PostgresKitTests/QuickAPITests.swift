import XCTest
import Logging
@testable import PostgresKit

final class QuickAPITests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!
    private var testLogger: Logger!

    override func setUp() async throws {
        try await super.setUp()
        testLogger = Logger(label: "postgres.wire.tests")

                guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }

        



        let config = PostgresConfiguration(
            host: TestEnv.host,
            port: TestEnv.port,
            database: TestEnv.database,
            username: TestEnv.username,
            password: TestEnv.password,
            useTLS: TestEnv.useTLS,
            applicationName: "QuickAPITests"
        )

        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: testLogger)
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    func testBasicCreateTableAPI() async throws {
        logger.info("Testing createTable API")

        do {
            // Clean up first
            _ = try await client.admin.dropTable(name: "quick_test", ifExists: true)

            // Test createTable API
            _ = try await client.admin.createTable(
                name: "quick_test",
                columns: [
                    .bigSerial(name: "id", primaryKey: true),
                    .text(name: "name", nullable: false),
                    .integer(name: "value", defaultValue: 0)
                ]
            )
            logger.info("createTable API successful")

            // Test insert API
            _ = try await client.bulk.insert(
                into: "quick_test",
                columns: ["name"],
                values: [["Test Record"]]
            )
            logger.info("insert API successful")

            // Verify data exists
            let result = try await client.simpleQuery("SELECT COUNT(*)::text FROM quick_test")
            for try await count in result.decode(String.self) {
                logger.info("Record count: \(count)")
                XCTAssertEqual(count, "1")
                break
            }

            // Clean up
            _ = try await client.admin.dropTable(name: "quick_test", ifExists: false)
            logger.info("dropTable API successful")

        } catch {
            logger.error("Quick API test failed: \(String(reflecting: error))")
            throw error
        }
    }

    func testBasicSequenceAPI() async throws {
        logger.info("Testing sequence API")

        do {
            // Clean up first
            _ = try await client.sequences.dropSequence(name: "quick_test_seq", ifExists: true)

            // Test createSequence API
            _ = try await client.sequences.createSequence(name: "quick_test_seq")
            logger.info("createSequence API successful")

            // Test nextval API
            let next1 = try await client.sequences.nextval("quick_test_seq")
            logger.info("nextval API successful, first value: \(next1)")

            let next2 = try await client.sequences.nextval("quick_test_seq")
            logger.info("nextval API successful, second value: \(next2)")

            // Verify sequence increments
            XCTAssertEqual(next2, next1 + 1)

            // Clean up
            _ = try await client.sequences.dropSequence(name: "quick_test_seq", ifExists: false)
            logger.info("dropSequence API successful")

        } catch {
            logger.error("Sequence API test failed: \(String(reflecting: error))")
            throw error
        }
    }
}