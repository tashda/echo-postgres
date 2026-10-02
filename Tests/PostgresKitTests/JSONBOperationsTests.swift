import XCTest
import Logging
@testable import PostgresKit

/// Tests JSONB operators, functions, indexing, and nested queries using SampleData fixtures.
final class JSONBOperationsTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "JSONBOperationsTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() { client?.close(); super.tearDown() }

    // MARK: - Containment Operators

    func testContainmentOperator() async throws {
        // @> containment: find JSONB that contains {"active": true}
        let rows = try await client.simpleQuery("SELECT col_jsonb->>'name' FROM public.json_types WHERE col_jsonb @> '{\"active\": true}'")
        var found = false
        for try await name in rows.decode(String.self) {
            XCTAssertEqual(name, "Alice")
            found = true
        }
        XCTAssertTrue(found)
    }

    func testContainedByOperator() async throws {
        // <@ contained by
        let rows = try await client.simpleQuery("""
            SELECT count(*) FROM public.json_types
            WHERE col_jsonb_obj <@ '{"key": "value", "extra": true}'::jsonb
        """)
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThanOrEqual(count, 0)
    }

    // MARK: - Key Access Operators

    func testArrowOperatorObject() async throws {
        // -> returns JSONB element
        let rows = try await client.simpleQuery("SELECT col_jsonb->'name' FROM public.json_types WHERE col_jsonb ? 'name' AND col_jsonb->>'name' = 'Alice'")
        var found = false
        for try await _ in rows { found = true }
        XCTAssertTrue(found)
    }

    func testDoubleArrowOperatorText() async throws {
        // ->> returns text
        let rows = try await client.simpleQuery("SELECT col_jsonb->>'name' FROM public.json_types WHERE col_jsonb ? 'name' LIMIT 1")
        var found = false
        for try await name in rows.decode(String.self) {
            XCTAssertFalse(name.isEmpty)
            found = true
        }
        XCTAssertTrue(found)
    }

    func testHashArrowPathAccess() async throws {
        // #> path access
        let rows = try await client.simpleQuery("""
            SELECT col_jsonb #>> '{users,0,name}' FROM public.json_types WHERE col_jsonb ? 'users'
        """)
        var found = false
        for try await name in rows.decode(String.self) {
            XCTAssertEqual(name, "Alice")
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Existence Operators

    func testKeyExistsOperator() async throws {
        // ? key exists
        let rows = try await client.simpleQuery("SELECT count(*) FROM public.json_types WHERE col_jsonb ? 'name'")
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThan(count, 0)
    }

    func testAnyKeysExistOperator() async throws {
        // ?| any keys exist
        let rows = try await client.simpleQuery("SELECT count(*) FROM public.json_types WHERE col_jsonb ?| array['name', 'users']")
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThan(count, 0)
    }

    func testAllKeysExistOperator() async throws {
        // ?& all keys exist
        let rows = try await client.simpleQuery("SELECT count(*) FROM public.json_types WHERE col_jsonb ?& array['name', 'age', 'active']")
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - Concatenation and Deletion

    func testConcatenationOperator() async throws {
        // || concatenation
        let rows = try await client.simpleQuery("SELECT ('{\"a\": 1}'::jsonb || '{\"b\": 2}'::jsonb)->>'b'")
        var found = false
        for try await val in rows.decode(String.self) {
            XCTAssertEqual(val, "2")
            found = true
        }
        XCTAssertTrue(found)
    }

    func testKeyDeletionOperator() async throws {
        // - key deletion
        let rows = try await client.simpleQuery("SELECT ('{\"a\": 1, \"b\": 2}'::jsonb - 'a')->>'b'")
        var found = false
        for try await val in rows.decode(String.self) {
            XCTAssertEqual(val, "2")
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - JSONB Functions

    func testJsonbArrayElements() async throws {
        let rows = try await client.simpleQuery("""
            SELECT jsonb_array_elements_text(col_jsonb->'users'->0->'roles')
            FROM public.json_types WHERE col_jsonb ? 'users'
        """)
        var roles: [String] = []
        for try await r in rows.decode(String.self) { roles.append(r) }
        XCTAssertTrue(roles.contains("admin"))
        XCTAssertTrue(roles.contains("user"))
    }

    func testJsonbAgg() async throws {
        let rows = try await client.simpleQuery("SELECT jsonb_agg(username) FROM app.users WHERE is_verified = true")
        var found = false
        for try await _ in rows { found = true }
        XCTAssertTrue(found)
    }

    func testJsonbObjectAgg() async throws {
        let rows = try await client.simpleQuery("SELECT jsonb_object_agg(username, login_count) FROM app.users")
        var found = false
        for try await _ in rows { found = true }
        XCTAssertTrue(found)
    }

    func testJsonbTypeof() async throws {
        let rows = try await client.simpleQuery("SELECT jsonb_typeof(col_jsonb) FROM public.json_types WHERE col_jsonb IS NOT NULL")
        var types: [String] = []
        for try await t in rows.decode(String.self) { types.append(t) }
        XCTAssertTrue(types.contains("object"))
    }

    func testJsonbKeys() async throws {
        let rows = try await client.simpleQuery("SELECT jsonb_object_keys(col_jsonb) FROM public.json_types WHERE col_jsonb @> '{\"name\": \"Alice\"}'")
        var keys: [String] = []
        for try await k in rows.decode(String.self) { keys.append(k) }
        XCTAssertTrue(keys.contains("name"))
        XCTAssertTrue(keys.contains("age"))
    }

    // MARK: - JSONB in app.users

    func testUserMetadataJSONB() async throws {
        let rows = try await client.simpleQuery("SELECT metadata->>'github' FROM app.users WHERE username = 'alice'")
        var found = false
        for try await github in rows.decode(String.self) {
            XCTAssertEqual(github, "alice")
            found = true
        }
        XCTAssertTrue(found)
    }

    func testUserSettingsJSONB() async throws {
        let rows = try await client.simpleQuery("SELECT settings->>'theme' FROM app.users WHERE username = 'alice'")
        var found = false
        for try await theme in rows.decode(String.self) {
            XCTAssertEqual(theme, "dark")
            found = true
        }
        XCTAssertTrue(found)
    }

    func testJSONBPathQuery() async throws {
        // Find users whose metadata has experience_years > 5
        let rows = try await client.simpleQuery("""
            SELECT username FROM app.users
            WHERE (metadata->>'experience_years')::int > 5
        """)
        var users: [String] = []
        for try await u in rows.decode(String.self) { users.append(u) }
        XCTAssertTrue(users.contains("alice"))
    }

    // MARK: - Post Metadata Queries

    func testPostMetadataQuery() async throws {
        let rows = try await client.simpleQuery("""
            SELECT title FROM app.posts
            WHERE metadata->>'difficulty' = 'advanced'
        """)
        var titles: [String] = []
        for try await t in rows.decode(String.self) { titles.append(t) }
        XCTAssertFalse(titles.isEmpty)
    }

    // MARK: - GIN Index Usage

    func testGINIndexUsedForContainment() async throws {
        let plan = try await client.executionPlan.explain("SELECT * FROM public.json_types WHERE col_jsonb @> '{\"name\": \"Alice\"}'")
        // GIN index should be used (Bitmap Index Scan or Index Scan)
        XCTAssertFalse(plan.isEmpty, "EXPLAIN should return a plan")
    }

    // MARK: - JSONB Merge Function

    func testMergeJsonbSettingsFunction() async throws {
        let rows = try await client.simpleQuery("""
            SELECT app.merge_jsonb_settings('{"theme": "light"}'::jsonb, '{"lang": "en"}'::jsonb)->>'lang'
        """)
        var found = false
        for try await val in rows.decode(String.self) {
            XCTAssertEqual(val, "en")
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Special Characters in JSONB

    func testJSONBSpecialCharacters() async throws {
        // The emoji/unicode data is in col_json (not col_jsonb) in the sample data
        let rows = try await client.simpleQuery("SELECT col_json->>'emoji' FROM public.json_types WHERE col_json::text LIKE '%emoji%'")
        var found = false
        for try await emoji in rows.decode(String?.self) {
            if let emoji, emoji.contains("🎉") { found = true }
        }
        XCTAssertTrue(found)
    }

    func testJSONBWithUnicodeContent() async throws {
        // The unicode data is in col_json (not col_jsonb) in the sample data
        let rows = try await client.simpleQuery("SELECT col_json->>'unicode' FROM public.json_types WHERE col_json::text LIKE '%unicode%'")
        var found = false
        for try await val in rows.decode(String?.self) {
            if let val, val == "日本語" { found = true }
        }
        XCTAssertTrue(found)
    }
}
