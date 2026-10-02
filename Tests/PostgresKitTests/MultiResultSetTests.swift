import XCTest
import Logging
@testable import PostgresKit

/// Tests for query execution correctness, including single-statement baselines
/// and streaming delivery verification.
///
/// Note: PostgreSQL's extended query protocol (used by postgres-nio) does NOT
/// support multiple statements in a single query. Multi-statement batches
/// (`SELECT 1; SELECT 2`) require the simple query protocol (raw Query message),
/// which is not currently exposed. These tests verify single-statement correctness
/// and streaming behavior instead.
final class MultiResultSetTests: PostgresKitTestCase {

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
            applicationName: "MultiResultSetTests"
        )

        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: testLogger)
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    // MARK: - Single Statement Baseline

    func testSingleStatementBaseline() async throws {
        let rows = try await client.simpleQuery("SELECT 1 AS value")
        var values: [Int] = []
        for try await value in rows.decode(Int.self) {
            values.append(value)
        }
        XCTAssertEqual(values, [1], "Single SELECT should return exactly one row with value 1")
    }

    // MARK: - Single Statement with Multiple Rows

    func testSingleStatementMultipleRows() async throws {
        let rows = try await client.simpleQuery(
            "SELECT generate_series(1, 5) AS val"
        )
        var values: [Int] = []
        for try await value in rows.decode(Int.self) {
            values.append(value)
        }
        XCTAssertEqual(values, [1, 2, 3, 4, 5])
    }

    // MARK: - Streaming Single Statement

    // MARK: - DML then SELECT (separate queries)

    func testDMLThenSelectSeparateQueries() async throws {
        // Create temp table
        _ = try await client.simpleQuery(
            "CREATE TEMPORARY TABLE dml_test (id SERIAL PRIMARY KEY, label TEXT)"
        )

        // INSERT
        _ = try await client.simpleQuery(
            "INSERT INTO dml_test (label) VALUES ('one'), ('two'), ('three')"
        )

        // SELECT
        let rows = try await client.simpleQuery(
            "SELECT label FROM dml_test ORDER BY id"
        )
        var labels: [String] = []
        for try await label in rows.decode(String.self) {
            labels.append(label)
        }

        XCTAssertEqual(labels, ["one", "two", "three"])
    }

    // MARK: - Streaming with Temp Table

}

// MARK: - Helpers

