import XCTest
import Logging
@testable import PostgresKit

final class SimpleSequenceTest: PostgresKitTestCase {
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
            applicationName: "SimpleSequenceTest"
        )

        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: testLogger)
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    func testBasicSequenceOperations() async throws {
        logger.info("Testing Basic Sequence Operations")

        // Clean up if sequence exists
        _ = try await client.sequences.dropSequence(name: "test_simple_seq", ifExists: true)

        // Create basic sequence
        _ = try await client.sequences.createSequence(name: "test_simple_seq")

        // Test nextval - using the new API method
        let nextVal1 = try await client.sequences.nextval("test_simple_seq")
        XCTAssertEqual(nextVal1, 1)

        let nextVal2 = try await client.sequences.nextval("test_simple_seq")
        XCTAssertEqual(nextVal2, 2)

        // Test currval (after nextval has been called) - using the new API method
        let currVal = try await client.sequences.currval("test_simple_seq")
        XCTAssertEqual(currVal, 2)

        // Test sequence with table - using the new API
        _ = try await client.admin.dropTable(name: "test_seq_table", ifExists: true)
        _ = try await client.admin.createTable(
            name: "test_seq_table",
            columns: [
                .integer(name: "id", nullable: false, defaultValue: nil),
                .varchar(name: "name", length: 50, nullable: false)
            ]
        )

        // Set up the default value using the alterColumnDefault API
        _ = try await client.admin.alterColumnDefault(table: "test_seq_table", column: "id", defaultValue: "nextval('test_simple_seq')")

        // Insert data using sequence
        _ = try await client.bulk.insert(into: "test_seq_table", columns: ["name"], values: [["test1"]])
        _ = try await client.bulk.insert(into: "test_seq_table", columns: ["name"], values: [["test2"]])

        // Verify sequence-generated IDs
        let resultRows = try await client.simpleQuery("SELECT id, name FROM test_seq_table ORDER BY id")
        var results: [(Int, String)] = []
        for try await (id, name) in resultRows.decode((Int, String).self) {
            results.append((id, name))
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].0, 3) // Should continue from 3
        XCTAssertEqual(results[0].1, "test1")
        XCTAssertEqual(results[1].0, 4)
        XCTAssertEqual(results[1].1, "test2")

        // Test setval - using the new API method
        _ = try await client.sequences.setval("test_simple_seq", value: 100)
        let nextVal3 = try await client.sequences.nextval("test_simple_seq")
        XCTAssertEqual(nextVal3, 101)

        // Clean up - using the new API
        _ = try await client.admin.dropTable(name: "test_seq_table", ifExists: false)
        _ = try await client.sequences.dropSequence(name: "test_simple_seq", ifExists: false)

        logger.info("Basic sequence operations test passed")
    }

    func testSequenceWithOptions() async throws {
        logger.info("Testing Sequence Options")

        // Clean up if sequence exists
        _ = try await client.sequences.dropSequence(name: "test_options_seq", ifExists: true)

        // Create sequence with options - using the new API
        _ = try await client.sequences.createSequence(
            name: "test_options_seq",
            startWith: 10,
            incrementBy: 5,
            minValue: 5,
            maxValue: 50,
            cycle: true
        )

        // Test initial value - using the new API method
        let nextVal1 = try await client.sequences.nextval("test_options_seq")
        XCTAssertEqual(nextVal1, 10)

        let nextVal2 = try await client.sequences.nextval("test_options_seq")
        XCTAssertEqual(nextVal2, 15)

        let nextVal3 = try await client.sequences.nextval("test_options_seq")
        XCTAssertEqual(nextVal3, 20)

        // Clean up
        _ = try await client.sequences.dropSequence(name: "test_options_seq", ifExists: false)

        logger.info("Sequence options test passed")
    }

    func testTemporarySequence() async throws {
        logger.info("Testing Temporary Sequence")

        // Create temporary sequence - using the new API
        _ = try await client.sequences.createSequence(
            name: "temp_test_seq",
            temporary: true,
            startWith: 1000
        )

        // Test temporary sequence - using the new API method
        let nextVal = try await client.sequences.nextval("temp_test_seq")
        XCTAssertEqual(nextVal, 1000)

        // Temporary sequences don't need explicit cleanup - dropped at session end
        logger.info("Temporary sequence test passed")
    }
}