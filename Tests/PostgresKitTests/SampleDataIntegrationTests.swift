import XCTest
import Logging
@testable import PostgresKit

/// Validates that all SampleData.sql fixtures are loaded correctly:
/// schemas, extensions, custom types, tables, views, triggers, functions, roles, and data.
final class SampleDataIntegrationTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "SampleDataIntegrationTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() { client?.close(); super.tearDown() }

    // MARK: - Schemas

    func testAllSchemasExist() async throws {
        let rows = try await client.simpleQuery("SELECT schema_name FROM information_schema.schemata")
        var schemas: [String] = []
        for try await s in rows.decode(String.self) { schemas.append(s) }
        for expected in ["public", "app", "audit", "archive"] {
            XCTAssertTrue(schemas.contains(expected), "Missing schema: \(expected)")
        }
    }

    // MARK: - Extensions

    func testRequiredExtensionsInstalled() async throws {
        let rows = try await client.simpleQuery("SELECT extname FROM pg_extension")
        var exts: [String] = []
        for try await e in rows.decode(String.self) { exts.append(e) }
        for expected in ["uuid-ossp", "hstore", "ltree", "citext"] {
            XCTAssertTrue(exts.contains(expected), "Missing extension: \(expected)")
        }
    }

    // MARK: - Custom Types

    func testEnumTypesExist() async throws {
        let rows = try await client.simpleQuery("SELECT typname FROM pg_type WHERE typtype = 'e' ORDER BY typname")
        var enums: [String] = []
        for try await e in rows.decode(String.self) { enums.append(e) }
        XCTAssertTrue(enums.contains("mood"))
        XCTAssertTrue(enums.contains("priority_level"))
        XCTAssertTrue(enums.contains("order_status"))
    }

    func testCompositeTypeExists() async throws {
        let rows = try await client.simpleQuery("SELECT typname FROM pg_type WHERE typtype = 'c' AND typname = 'address_type'")
        var found = false
        for try await _ in rows { found = true }
        XCTAssertTrue(found, "address_type composite type should exist")
    }

    func testDomainTypesExist() async throws {
        let rows = try await client.simpleQuery("SELECT typname FROM pg_type WHERE typtype = 'd' AND typname IN ('positive_integer', 'email_address', 'percentage')")
        var domains: [String] = []
        for try await d in rows.decode(String.self) { domains.append(d) }
        XCTAssertEqual(domains.count, 3, "Should have 3 domain types")
    }

    // MARK: - Tables with Row Counts

    func testPublicTypeTablesHaveData() async throws {
        let tables = ["numeric_types", "text_types", "temporal_types", "json_types",
                      "array_types", "network_types", "geometric_types", "binary_types",
                      "range_types", "fulltext_types", "special_types", "all_data_types"]
        for table in tables {
            let rows = try await client.simpleQuery("SELECT count(*) FROM public.\(table)")
            var count: Int64 = 0
            for try await c in rows.decode(Int64.self) { count = c }
            XCTAssertGreaterThan(count, 0, "Table public.\(table) should have data")
        }
    }

    func testAppTablesHaveData() async throws {
        let tables: [(String, Int64)] = [
            ("users", 5), ("user_profiles", 3), ("posts", 5),
            ("tags", 5), ("post_tags", 8), ("comments", 6),
            ("orders", 3), ("order_items", 4)
        ]
        for (table, minCount) in tables {
            let rows = try await client.simpleQuery("SELECT count(*) FROM app.\(table)")
            var count: Int64 = 0
            for try await c in rows.decode(Int64.self) { count = c }
            XCTAssertGreaterThanOrEqual(count, minCount, "app.\(table) should have >= \(minCount) rows")
        }
    }

    // MARK: - Views

    func testViewsAreQueryable() async throws {
        let views = ["app.active_users", "app.published_posts", "app.post_statistics"]
        for view in views {
            let rows = try await client.simpleQuery("SELECT count(*) FROM \(view)")
            var count: Int64 = 0
            for try await c in rows.decode(Int64.self) { count = c }
            XCTAssertGreaterThanOrEqual(count, 0, "View \(view) should be queryable")
        }
    }

    func testMaterializedViewIsQueryable() async throws {
        let rows = try await client.simpleQuery("SELECT count(*) FROM app.user_activity_summary")
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThan(count, 0, "Materialized view should have data")
    }

    // MARK: - Functions

    func testFunctionsExist() async throws {
        let functions = ["update_updated_at", "update_post_search_vector", "update_tag_count",
                         "increment_login_count", "get_user_posts", "merge_jsonb_settings"]
        for fn in functions {
            let rows = try await client.simpleQuery("SELECT proname FROM pg_proc WHERE proname = '\(fn)'")
            var found = false
            for try await _ in rows { found = true }
            XCTAssertTrue(found, "Function \(fn) should exist")
        }
    }

    func testAuditLogFunctionExists() async throws {
        let rows = try await client.simpleQuery("SELECT proname FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'audit' AND p.proname = 'log_change'")
        var found = false
        for try await _ in rows { found = true }
        XCTAssertTrue(found, "audit.log_change() function should exist")
    }

    // MARK: - Triggers

    func testTriggersAttached() async throws {
        let triggers = [
            ("trg_users_updated_at", "users"),
            ("trg_posts_updated_at", "posts"),
            ("trg_posts_search_vector", "posts"),
            ("trg_post_tags_count", "post_tags"),
            ("trg_users_audit", "users"),
            ("trg_posts_audit", "posts")
        ]
        for (trigName, tableName) in triggers {
            let rows = try await client.simpleQuery(
                "SELECT tgname FROM pg_trigger t JOIN pg_class c ON t.tgrelid = c.oid WHERE tgname = '\(trigName)' AND c.relname = '\(tableName)'"
            )
            var found = false
            for try await _ in rows { found = true }
            XCTAssertTrue(found, "Trigger \(trigName) should be attached to \(tableName)")
        }
    }

    // MARK: - Roles

    func testTestRolesExist() async throws {
        let rows = try await client.simpleQuery("SELECT rolname FROM pg_roles WHERE rolname LIKE 'test_%'")
        var roles: [String] = []
        for try await r in rows.decode(String.self) { roles.append(r) }
        XCTAssertTrue(roles.contains("test_readonly"))
        XCTAssertTrue(roles.contains("test_readwrite"))
        XCTAssertTrue(roles.contains("test_app_user"))
    }

    // MARK: - Sequences

    func testSequencesExist() async throws {
        let rows = try await client.simpleQuery(
            "SELECT sequencename FROM pg_sequences WHERE schemaname = 'app' AND sequencename IN ('invoice_number_seq', 'ticket_number_seq')"
        )
        var seqs: [String] = []
        for try await s in rows.decode(String.self) { seqs.append(s) }
        XCTAssertTrue(seqs.contains("invoice_number_seq"))
        XCTAssertTrue(seqs.contains("ticket_number_seq"))
    }

    // MARK: - Complex Queries

    func testMultiTableJoin() async throws {
        let rows = try await client.simpleQuery("""
            SELECT u.username, p.title, COUNT(c.id) AS comment_count
            FROM app.users u
            JOIN app.posts p ON p.author_id = u.id
            LEFT JOIN app.comments c ON c.post_id = p.id
            GROUP BY u.username, p.title
            HAVING COUNT(c.id) > 0
            ORDER BY comment_count DESC
        """)
        var count = 0
        for try await _ in rows { count += 1 }
        XCTAssertGreaterThan(count, 0, "Should find posts with comments")
    }

    func testCTEQuery() async throws {
        let rows = try await client.simpleQuery("""
            WITH user_stats AS (
                SELECT u.id, u.username,
                       COUNT(DISTINCT p.id) AS posts,
                       COUNT(DISTINCT c.id) AS comments
                FROM app.users u
                LEFT JOIN app.posts p ON p.author_id = u.id
                LEFT JOIN app.comments c ON c.author_id = u.id
                GROUP BY u.id, u.username
            )
            SELECT username, posts, comments FROM user_stats WHERE posts > 0 ORDER BY posts DESC
        """)
        var count = 0
        for try await _ in rows { count += 1 }
        XCTAssertGreaterThan(count, 0, "Should find users with posts")
    }

    func testWindowFunctionQuery() async throws {
        let rows = try await client.simpleQuery("""
            SELECT title, view_count,
                   RANK() OVER (ORDER BY view_count DESC) AS view_rank,
                   SUM(view_count) OVER () AS total_views
            FROM app.posts
            WHERE status = 'delivered'
        """)
        var count = 0
        for try await _ in rows { count += 1 }
        XCTAssertGreaterThan(count, 0, "Should return ranked posts")
    }

    func testSubqueryWithExists() async throws {
        let rows = try await client.simpleQuery("""
            SELECT u.username FROM app.users u
            WHERE EXISTS (
                SELECT 1 FROM app.posts p WHERE p.author_id = u.id AND p.status = 'delivered'
            )
        """)
        var count = 0
        for try await _ in rows { count += 1 }
        XCTAssertGreaterThan(count, 0, "Should find users with delivered posts")
    }

    // MARK: - Comments

    func testTableComments() async throws {
        let comment = try await client.metadata.fetchTableComment(schema: "app", table: "users")
        XCTAssertEqual(comment, "Core user accounts table")
    }

    func testColumnComments() async throws {
        let comments = try await client.metadata.fetchColumnComments(schema: "app", table: "users")
        let metadataComment = comments.first { $0.column == "metadata" }
        XCTAssertNotNil(metadataComment, "metadata column should have a comment")
    }
}
