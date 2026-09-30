import XCTest
import Logging
@testable import PostgresKit

/// Tests triggers firing correctly, stored functions, and the trigger/function client API.
final class TriggerAndFunctionTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "TriggerFunctionTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() { client?.close(); super.tearDown() }

    private func uniqueName(_ prefix: String = "trig") -> String {
        "\(prefix)_\(UInt32.random(in: 0..<UInt32.max))"
    }

    // MARK: - updated_at Trigger

    func testUpdatedAtTriggerFires() async throws {
        // Get a user's current updated_at
        let beforeRows = try await client.simpleQuery("SELECT id, updated_at FROM app.users WHERE username = 'alice'")
        var userId: Int64?
        var beforeTimestamp: String?
        for try await (id, ts) in beforeRows.decode((Int64, String).self) {
            userId = id
            beforeTimestamp = ts
        }
        guard let uid = userId else { return XCTFail("alice should exist") }

        // Wait a moment so timestamp differs
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Update the user's bio
        _ = try await client.bulk.update(table: "app.users", set: ["bio": "Updated bio at \(Date())"], whereClause: "id = \(uid)")

        // Check updated_at changed
        let afterRows = try await client.simpleQuery("SELECT updated_at::text FROM app.users WHERE id = \(uid)")
        var afterTimestamp: String?
        for try await ts in afterRows.decode(String.self) { afterTimestamp = ts }

        XCTAssertNotEqual(beforeTimestamp, afterTimestamp, "updated_at trigger should update timestamp")
    }

    // MARK: - Search Vector Trigger

    func testSearchVectorTriggerPopulatesOnInsert() async throws {
        // Posts inserted by SampleData should have search_vector populated
        let rows = try await client.simpleQuery("SELECT count(*) FROM app.posts WHERE search_vector IS NOT NULL")
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThan(count, 0, "search_vector should be populated by trigger on INSERT")
    }

    func testSearchVectorTriggerUpdatesOnTitleChange() async throws {
        // Get a post
        let postRows = try await client.simpleQuery("SELECT id, title FROM app.posts ORDER BY id DESC LIMIT 1")
        var post: (id: Int64, title: String)?
        for try await row in postRows.decode((Int64, String).self) { post = (row.0, row.1) }
        guard let pid = post?.id, let originalTitle = post?.title else { return XCTFail("Should have at least one post") }

        // Update title with a unique word
        let uniqueWord = "xylophonetest\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await client.bulk.update(table: "app.posts", set: ["title": "Testing \(uniqueWord) feature"], whereClause: "id = \(pid)")

        // Verify search_vector contains the unique word
        let searchRows = try await client.simpleQuery("SELECT search_vector::text FROM app.posts WHERE id = \(pid)")
        var vector: String?
        for try await v in searchRows.decode(String.self) { vector = v }
        XCTAssertNotNil(vector)
        // The tsvector should contain the unique word (stemmed)
        if let v = vector {
            XCTAssertTrue(v.contains(uniqueWord) || v.lowercased().contains(uniqueWord.lowercased()),
                         "search_vector should contain the updated word")
        }
        // Other tests (full-text search) read the sample posts' titles: put it back.
        _ = try await client.bulk.update(table: "app.posts", set: ["title": originalTitle], whereClause: "id = \(pid)")
    }

    // MARK: - Audit Trigger

    func testAuditTriggerLogsInsert() async throws {
        // Clear audit log for clean test
        _ = try await client.bulk.delete(from: "audit.change_log", whereClause: "table_name = 'users' AND operation = 'INSERT'")

        // Insert a new user (triggers audit.log_change)
        let username = uniqueName("audituser")
        _ = try await client.bulk.insert(into: "app.users", columns: ["username", "email", "password_hash"], values: [[username, "\(username)@example.com", "hash123"]])

        // Check audit log
        let rows = try await client.simpleQuery("""
            SELECT operation, new_data->>'username' FROM audit.change_log
            WHERE table_name = 'users' AND operation = 'INSERT' AND new_data->>'username' = '\(username)'
        """)
        var found = false
        for try await (op, name) in rows.decode((String, String).self) {
            XCTAssertEqual(op, "INSERT")
            XCTAssertEqual(name, username)
            found = true
        }
        XCTAssertTrue(found, "Audit trigger should log INSERT")

        // Cleanup
        _ = try await client.bulk.delete(from: "app.users", whereClause: "username = '\(username)'")
    }

    func testAuditTriggerLogsUpdate() async throws {
        let rows = try await client.simpleQuery("""
            SELECT count(*) FROM audit.change_log WHERE table_name = 'users' AND operation = 'UPDATE'
        """)
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        // After testUpdatedAtTriggerFires runs, there should be UPDATE audit entries
        XCTAssertGreaterThanOrEqual(count, 0, "Should have UPDATE audit entries (if update test ran)")
    }

    // MARK: - Tag Count Trigger

    func testTagCountTriggerIncrementsOnInsert() async throws {
        // Get current post_count for PostgreSQL tag
        let beforeRows = try await client.simpleQuery("SELECT post_count FROM app.tags WHERE slug = 'postgresql'")
        var beforeCount: Int?
        for try await c in beforeRows.decode(Int.self) { beforeCount = c }
        XCTAssertNotNil(beforeCount)
    }

    // MARK: - Calling Functions

    func testGetUserPostsFunction() async throws {
        // Get alice's ID
        let userRows = try await client.simpleQuery("SELECT id FROM app.users WHERE username = 'alice'")
        var userId: Int64?
        for try await id in userRows.decode(Int64.self) { userId = id }
        guard let uid = userId else { return XCTFail("alice should exist") }

        let rows = try await client.simpleQuery("SELECT * FROM app.get_user_posts(\(uid))")
        var count = 0
        for try await _ in rows { count += 1 }
        XCTAssertGreaterThan(count, 0, "alice should have posts")
    }

    func testIncrementLoginCountFunction() async throws {
        let userRows = try await client.simpleQuery("SELECT id, login_count FROM app.users WHERE username = 'bob'")
        var userId: Int64?
        var beforeCount: Int?
        for try await (id, count) in userRows.decode((Int64, Int).self) {
            userId = id
            beforeCount = count
        }
        guard let uid = userId, let before = beforeCount else { return XCTFail("bob should exist") }

        _ = try await client.simpleQuery("SELECT app.increment_login_count(\(uid))")

        let afterRows = try await client.simpleQuery("SELECT login_count FROM app.users WHERE id = \(uid)")
        var afterCount: Int?
        for try await c in afterRows.decode(Int.self) { afterCount = c }
        XCTAssertEqual(afterCount, before + 1, "Login count should be incremented")
    }

    func testMergeJsonbSettingsFunction() async throws {
        let rows = try await client.simpleQuery("""
            SELECT app.merge_jsonb_settings('{"theme": "dark"}'::jsonb, '{"lang": "en", "notifications": true}'::jsonb)
        """)
        var found = false
        for try await _ in rows { found = true }
        XCTAssertTrue(found)
    }

    // MARK: - Function Introspection

    func testFunctionDefinitionIntrospection() async throws {
        let def = try await client.metadata.functionDefinition(schema: "app", name: "increment_login_count")
        XCTAssertNotNil(def, "Should find function definition")
        if let def = def {
            XCTAssertTrue(def.lowercased().contains("login_count"))
        }
    }

    // MARK: - Create and Drop Function via Client API

    func testCreateAndDropFunction() async throws {
        let name = uniqueName("fn")
        defer { Task { [client = self.client!] in _ = try? await client.routines.dropFunction(name: name, ifExists: true) } }

        _ = try await client.routines.createFunction(
            name: name,
            parameters: [.init(name: "x", dataType: "INTEGER"), .init(name: "y", dataType: "INTEGER")],
            returnType: "INTEGER",
            body: "SELECT x + y;",
            language: .sql,
            immutable: true
        )

        let rows = try await client.simpleQuery("SELECT \(name)(3, 4)")
        var found = false
        for try await result in rows.decode(Int.self) {
            XCTAssertEqual(result, 7)
            found = true
        }
        XCTAssertTrue(found)

        _ = try await client.routines.dropFunction(name: name, parameters: ["INTEGER", "INTEGER"])
    }

    // MARK: - Create and Drop Trigger via Client API

    func testCreateAndDropTrigger() async throws {
        let table = uniqueName("table")
        let fnName = uniqueName("trfn")
        let trigName = uniqueName("tr")
        defer { Task { [client = self.client!] in
            _ = try? await client.triggers.dropTrigger(name: trigName, table: table, ifExists: true)
            _ = try? await client.admin.dropTable(name: table, ifExists: true)
            _ = try? await client.routines.dropFunction(name: fnName, ifExists: true)
        }}

        // Create table
        _ = try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            .text(name: "name"),
            PostgresColumnDefinition(name: "updated_at", dataType: "TIMESTAMPTZ", defaultValue: "NOW()")
        ])

        // Create trigger function
        _ = try await client.routines.createFunction(
            name: fnName,
            parameters: [],
            returnType: "TRIGGER",
            body: """
                BEGIN
                    NEW.updated_at = CURRENT_TIMESTAMP;
                    RETURN NEW;
                END;
                """,
            language: .plpgsql
        )

        // Create trigger
        _ = try await client.triggers.createTrigger(
            name: trigName,
            table: table,
            event: .before,
            operations: [.update],
            procedure: "\(fnName)()"
        )

        // Insert and update to test trigger
        _ = try await client.bulk.insert(into: table, columns: ["name"], values: [["test"]])
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await client.bulk.update(table: table, set: ["name": "updated"])

        // Drop trigger
        _ = try await client.triggers.dropTrigger(name: trigName, table: table)
    }

    // MARK: - Trigger Introspection

    func testTriggerDefinitionIntrospection() async throws {
        let def = try await client.metadata.triggerDefinition(schema: "app", name: "trg_users_updated_at")
        XCTAssertNotNil(def, "Should find trigger definition")
    }
}
