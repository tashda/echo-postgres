import XCTest
import Logging
@testable import PostgresKit

/// GP-05 (echo-server-lab driver gaps): per-column collation, operator class parameters,
/// storage parameters, and NULLS NOT DISTINCT on indexes and unique constraints, checked against
/// the definition the server stores.
final class IndexOptionsTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!
    private let table = "index_options_t"

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        client = try await PostgresKit.PostgresClient.connect(configuration: PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port, database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS, applicationName: "IndexOptionsTests"), logger: logger)
        _ = try await client.admin.dropTable(name: table, ifExists: true, cascade: true)
        _ = try await client.simpleQueryResult("CREATE TABLE \(table) (id int, code text, document tsvector, region text)")
    }

    override func tearDown() async throws {
        _ = try? await client?.admin.dropTable(name: table, ifExists: true, cascade: true)
        client?.close()
        try await super.tearDown()
    }

    private func definition(of index: String) async throws -> String {
        let result = try await client.simpleQueryResult("SELECT indexdef FROM pg_indexes WHERE indexname = '\(index)'")
        let cell = try XCTUnwrap(result.rows.first?.first)
        return try XCTUnwrap(PostgresCellFormatter().stringValue(for: cell))
    }

    private func serverVersion() async throws -> Int {
        let result = try await client.simpleQueryResult("SHOW server_version_num")
        return Int(PostgresCellFormatter().stringValue(for: try XCTUnwrap(result.rows.first?.first)) ?? "") ?? 0
    }

    func testCollationAndOperatorClassPerColumn() async throws {
        try await client.indexes.createAdvancedIndex(
            name: "index_options_code", table: table,
            columns: [PostgresIndexColumn(name: "code", collation: "C", operatorClass: "text_pattern_ops", order: .desc)])
        let definition = try await definition(of: "index_options_code")
        XCTAssertTrue(definition.contains(#"(code COLLATE "C" text_pattern_ops DESC)"#), definition)
    }

    func testOperatorClassParametersAndStorageParameters() async throws {
        guard try await serverVersion() >= 130000 else { throw XCTSkip("operator class parameters need PostgreSQL 13") }
        try await client.indexes.createAdvancedIndex(
            name: "index_options_document", table: table,
            columns: [PostgresIndexColumn(name: "document", operatorClass: "tsvector_ops", operatorClassParameters: ["siglen": "32"])],
            indexType: .gist, storageParameters: ["fillfactor": "70"])
        let definition = try await definition(of: "index_options_document")
        XCTAssertTrue(definition.contains("tsvector_ops (siglen='32')") || definition.contains("tsvector_ops(siglen='32')"), definition)
        XCTAssertTrue(definition.contains("WITH (fillfactor='70')"), definition)
    }

    func testNullsNotDistinctWithAWhereClauseAndTablespace() async throws {
        guard try await serverVersion() >= 150000 else { throw XCTSkip("NULLS NOT DISTINCT needs PostgreSQL 15") }
        try await client.indexes.createAdvancedIndex(
            name: "index_options_region", table: table, columns: [PostgresIndexColumn(name: "region")],
            unique: true, include: ["id"], whereClause: "id > 0", tablespace: "pg_default", nullsDistinct: false)
        let definition = try await definition(of: "index_options_region")
        XCTAssertTrue(definition.contains("INCLUDE (id) NULLS NOT DISTINCT WHERE (id > 0)"), definition)
        _ = try await client.simpleQueryResult("INSERT INTO \(table) (id) VALUES (1)")
        do {
            _ = try await client.simpleQueryResult("INSERT INTO \(table) (id) VALUES (2)")
            XCTFail("a second NULL region is a duplicate")
        } catch {}
    }

    func testUniqueConstraintNullsNotDistinct() async throws {
        guard try await serverVersion() >= 150000 else { throw XCTSkip("NULLS NOT DISTINCT needs PostgreSQL 15") }
        try await client.constraints.addUniqueConstraint(table: table, columns: ["code"], constraintName: "index_options_code_unique",
                                                         nullsDistinct: false)
        let result = try await client.simpleQueryResult(
            "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'index_options_code_unique'")
        XCTAssertEqual(PostgresCellFormatter().stringValue(for: try XCTUnwrap(result.rows.first?.first)), "UNIQUE NULLS NOT DISTINCT (code)")
        _ = try await client.simpleQueryResult("INSERT INTO \(table) (id) VALUES (1)")
        do {
            _ = try await client.simpleQueryResult("INSERT INTO \(table) (id) VALUES (2)")
            XCTFail("a second NULL code is a duplicate")
        } catch {}
    }

    func testParametersAreQuotedUnlessPlain() async throws {
        XCTAssertEqual(PostgresIndexClient.parameterList(["siglen": "32", "fastupdate": "off"], client: client), "fastupdate = off, siglen = 32")
        XCTAssertEqual(PostgresIndexClient.parameterList(["odd name": "a'b c"], client: client), #""odd name" = 'a''b c'"#)
    }
}
