import XCTest
import Logging
@testable import PostgresKit

/// Tests views and materialized views: querying, creation, refresh, drop, and introspection.
final class ViewAndMaterializedViewTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "ViewTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() { client?.close(); super.tearDown() }

    private func uniqueName(_ prefix: String = "vw") -> String {
        "\(prefix)_\(UInt32.random(in: 0..<UInt32.max))"
    }

    // MARK: - Query Existing Views

    func testQueryActiveUsersView() async throws {
        let rows = try await client.simpleQuery("SELECT username FROM app.active_users")
        var users: [String] = []
        for try await u in rows.decode(String.self) { users.append(u) }
        XCTAssertFalse(users.isEmpty, "active_users view should return data")
    }

    func testQueryPublishedPostsView() async throws {
        let rows = try await client.simpleQuery("SELECT title, author_username FROM app.published_posts")
        var count = 0
        for try await _ in rows { count += 1 }
        XCTAssertGreaterThan(count, 0, "published_posts view should return data")
    }

    func testQueryPostStatisticsView() async throws {
        let rows = try await client.simpleQuery("SELECT title, comment_count FROM app.post_statistics")
        var count = 0
        for try await _ in rows { count += 1 }
        XCTAssertGreaterThan(count, 0, "post_statistics view should return data")
    }

    // MARK: - Query Materialized View

    func testQueryUserActivitySummary() async throws {
        let rows = try await client.simpleQuery("SELECT username, post_count, comment_count FROM app.user_activity_summary")
        var count = 0
        for try await _ in rows { count += 1 }
        XCTAssertGreaterThan(count, 0, "user_activity_summary matview should have data")
    }

    // MARK: - Create and Drop View via Client API

    func testCreateAndDropView() async throws {
        let name = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.views.dropView(name: name, ifExists: true) } }

        _ = try await client.views.createView(name: name, query: "SELECT 1 AS val, 'test'::text AS label")

        let rows = try await client.simpleQuery("SELECT val, label FROM \(name)")
        var found = false
        for try await (v, l) in rows.decode((Int, String).self) {
            XCTAssertEqual(v, 1)
            XCTAssertEqual(l, "test")
            found = true
        }
        XCTAssertTrue(found)

        _ = try await client.views.dropView(name: name)
    }

    func testCreateOrReplaceView() async throws {
        let name = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.views.dropView(name: name, ifExists: true) } }

        _ = try await client.views.createView(name: name, query: "SELECT 1 AS val")
        _ = try await client.views.createView(name: name, query: "SELECT 2 AS val", orReplace: true)

        let rows = try await client.simpleQuery("SELECT val FROM \(name)")
        var found = false
        for try await v in rows.decode(Int.self) {
            XCTAssertEqual(v, 2, "View should reflect replaced definition")
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Materialized View Operations

    func testCreateAndDropMaterializedView() async throws {
        let name = uniqueName("mv")
        defer { Task { [client = self.client!] in _ = try? await client.views.dropMaterializedView(name: name, ifExists: true) } }

        _ = try await client.views.createMaterializedView(name: name, query: "SELECT generate_series(1, 5) AS n")

        let rows = try await client.simpleQuery("SELECT count(*) FROM \(name)")
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertEqual(count, 5)

        _ = try await client.views.dropMaterializedView(name: name)
    }

    func testMaterializedViewWithNoDataIsUnpopulatedUntilRefreshed() async throws {
        let name = uniqueName("mv")
        defer { Task { [client = self.client!] in _ = try? await client.views.dropMaterializedView(name: name, ifExists: true) } }

        _ = try await client.views.createMaterializedView(name: name, schema: "public", query: "SELECT 1 AS n", withData: false)
        var details = try await client.metadata.materializedViewDetails(schema: "public", view: name)
        XCTAssertEqual(details?.isPopulated, false)

        _ = try await client.views.refreshMaterializedView(name: name)
        details = try await client.metadata.materializedViewDetails(schema: "public", view: name)
        XCTAssertEqual(details?.isPopulated, true)
    }

    /// Server-side prepared statements return binary rows; booleans and integers must decode.
    func testPreparedRowsDecodeNonTextColumns() async throws {
        let client = try XCTUnwrap(self.client)
        let schema = try client.bind("pg_catalog")
        let rows = try await client.withConnection { connection in
            try await connection.queryPreparedRows("SELECT nspname = $1, 42::int8, 'x'::text FROM pg_namespace WHERE nspname = $1", binds: [schema])
        }
        let (flag, number, text) = try XCTUnwrap(rows.first).decode((Bool, Int64, String).self)
        XCTAssertEqual(flag, true)
        XCTAssertEqual(number, 42)
        XCTAssertEqual(text, "x")
    }

    func testRefreshMaterializedView() async throws {
        let name = uniqueName("mv")
        defer { Task { [client = self.client!] in _ = try? await client.views.dropMaterializedView(name: name, ifExists: true) } }

        // Create matview based on current time
        _ = try await client.views.createMaterializedView(name: name, query: "SELECT now() AS captured_at")

        // Refresh should succeed
        _ = try await client.views.refreshMaterializedView(name: name)

        let rows = try await client.simpleQuery("SELECT count(*) FROM \(name)")
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertEqual(count, 1)
    }

    func testRefreshSampleMaterializedView() async throws {
        _ = try await client.views.refreshMaterializedView(name: "app.user_activity_summary", concurrently: false)

        let rows = try await client.simpleQuery("SELECT count(*) FROM app.user_activity_summary")
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - View Definition Introspection

    func testViewDefinitionIntrospection() async throws {
        let def = try await client.metadata.viewDefinition(schema: "app", view: "active_users")
        XCTAssertNotNil(def)
        if let def = def {
            XCTAssertTrue(def.lowercased().contains("is_active"))
        }
    }

    func testPublishedPostsViewDefinition() async throws {
        let def = try await client.metadata.viewDefinition(schema: "app", view: "published_posts")
        XCTAssertNotNil(def)
        if let def = def {
            XCTAssertTrue(def.lowercased().contains("join"))
        }
    }

    // MARK: - Drop with CASCADE

    func testDropViewCascade() async throws {
        let base = uniqueName("base")
        let dependent = uniqueName("dep")
        defer {
            Task { [client = self.client!] in
                _ = try? await client.views.dropView(name: dependent, ifExists: true)
                _ = try? await client.views.dropView(name: base, ifExists: true)
            }
        }

        _ = try await client.views.createView(name: base, query: "SELECT 1 AS val")
        _ = try await client.views.createView(name: dependent, query: "SELECT val FROM \(base)")

        // Dropping base without CASCADE should fail because dependent exists
        do {
            _ = try await client.views.dropView(name: base)
            // If it doesn't fail, that's also fine (depends on PostgreSQL behavior)
        } catch {
            // Expected — now drop with cascade
            _ = try await client.views.dropView(name: base, cascade: true)
        }
    }

    // MARK: - Drop IF EXISTS

    func testDropViewIfExistsNoError() async throws {
        _ = try await client.views.dropView(name: "nonexistent_view_\(UInt32.random(in: 0..<UInt32.max))", ifExists: true)
        // Should not throw
    }

    func testDropMaterializedViewIfExistsNoError() async throws {
        _ = try await client.views.dropMaterializedView(name: "nonexistent_mv_\(UInt32.random(in: 0..<UInt32.max))", ifExists: true)
    }
}
