import XCTest
import Logging
@testable import PostgresKit

final class QueryExecutionResultTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }

        let config = PostgresConfiguration(
            host: TestEnv.host,
            port: TestEnv.port,
            database: TestEnv.database,
            username: TestEnv.username,
            password: TestEnv.password,
            useTLS: TestEnv.useTLS,
            applicationName: "QueryExecutionResultTests"
        )

        client = try await PostgresKit.PostgresClient.connect(
            configuration: config,
            logger: Logger(label: "postgres.wire.tests")
        )
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    func testSimpleQueryResultReturnsRawCommandMetadataForSelect() async throws {
        let result = try await client.simpleQueryResult("SELECT 1 AS value")

        XCTAssertEqual(result.metadata.command, "SELECT")
        XCTAssertEqual(result.metadata.rows, 1)
        XCTAssertEqual(result.rows.count, 1)
    }

    func testSimpleQueryResultReturnsRawCommandMetadataForDDL() async throws {
        let tableName = "query_result_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let create = try await client.simpleQueryResult("CREATE TABLE \(tableName) (id integer)")
        XCTAssertEqual(create.metadata.command, "CREATE TABLE")
        XCTAssertNil(create.metadata.rows)
        XCTAssertTrue(create.rows.isEmpty)
        _ = try? await client.simpleQueryResult("DROP TABLE IF EXISTS \(tableName)")
    }
}
