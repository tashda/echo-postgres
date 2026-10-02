import XCTest
import Logging
@testable import PostgresKit

/// Tests role-based access control, permission enforcement, and the role/privilege client API.
final class PermissionAndRoleTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "PermissionAndRoleTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() { client?.close(); super.tearDown() }

    private func uniqueName(_ prefix: String = "role") -> String {
        "\(prefix)_\(UInt32.random(in: 0..<UInt32.max))"
    }

    // MARK: - SampleData Role Existence

    func testSampleDataRolesExist() async throws {
        let roles = try await client.security.listRoles()
        let roleNames = roles.map { $0.name }
        XCTAssertTrue(roleNames.contains("test_readonly"), "Should have test_readonly role")
        XCTAssertTrue(roleNames.contains("test_readwrite"), "Should have test_readwrite role")
        XCTAssertTrue(roleNames.contains("test_app_user"), "Should have test_app_user role")
    }

    func testReadonlyRoleHasNoLogin() async throws {
        let rows = try await client.simpleQuery("SELECT rolcanlogin FROM pg_roles WHERE rolname = 'test_readonly'")
        var canLogin: Bool?
        for try await val in rows.decode(Bool.self) { canLogin = val }
        XCTAssertEqual(canLogin, false, "test_readonly should not have LOGIN")
    }

    func testAppUserRoleHasLogin() async throws {
        let rows = try await client.simpleQuery("SELECT rolcanlogin FROM pg_roles WHERE rolname = 'test_app_user'")
        var canLogin: Bool?
        for try await val in rows.decode(Bool.self) { canLogin = val }
        XCTAssertEqual(canLogin, true, "test_app_user should have LOGIN")
    }

    // MARK: - Permission Verification via pg_has_table_privilege

    func testReadonlyHasSelectOnAppTables() async throws {
        let rows = try await client.simpleQuery("""
            SELECT has_table_privilege('test_readonly', 'app.users', 'SELECT')
        """)
        var hasSelect: Bool?
        for try await val in rows.decode(Bool.self) { hasSelect = val }
        XCTAssertEqual(hasSelect, true, "test_readonly should have SELECT on app.users")
    }

    func testReadonlyCannotInsertAppTables() async throws {
        let rows = try await client.simpleQuery("""
            SELECT has_table_privilege('test_readonly', 'app.users', 'INSERT')
        """)
        var hasInsert: Bool?
        for try await val in rows.decode(Bool.self) { hasInsert = val }
        XCTAssertEqual(hasInsert, false, "test_readonly should NOT have INSERT on app.users")
    }

    func testReadwriteHasFullDMLOnAppTables() async throws {
        let privRows = try await client.simpleQuery("""
            SELECT
                has_table_privilege('test_readwrite', 'app.users', 'SELECT') AS sel,
                has_table_privilege('test_readwrite', 'app.users', 'INSERT') AS ins,
                has_table_privilege('test_readwrite', 'app.users', 'UPDATE') AS upd,
                has_table_privilege('test_readwrite', 'app.users', 'DELETE') AS del
        """)
        for try await (sel, ins, upd, del) in privRows.decode((Bool, Bool, Bool, Bool).self) {
            XCTAssertTrue(sel, "test_readwrite should have SELECT")
            XCTAssertTrue(ins, "test_readwrite should have INSERT")
            XCTAssertTrue(upd, "test_readwrite should have UPDATE")
            XCTAssertTrue(del, "test_readwrite should have DELETE")
        }
    }

    func testReadonlyCannotUpdateOrDelete() async throws {
        let rows = try await client.simpleQuery("""
            SELECT
                has_table_privilege('test_readonly', 'app.posts', 'UPDATE') AS upd,
                has_table_privilege('test_readonly', 'app.posts', 'DELETE') AS del
        """)
        for try await (upd, del) in rows.decode((Bool, Bool).self) {
            XCTAssertFalse(upd, "test_readonly should NOT have UPDATE on app.posts")
            XCTAssertFalse(del, "test_readonly should NOT have DELETE on app.posts")
        }
    }

    // MARK: - Role Inheritance

    func testAppUserInheritsReadonly() async throws {
        // test_app_user should inherit test_readonly permissions
        let rows = try await client.simpleQuery("""
            SELECT pg_has_role('test_app_user', 'test_readonly', 'MEMBER')
        """)
        var isMember: Bool?
        for try await val in rows.decode(Bool.self) { isMember = val }
        XCTAssertEqual(isMember, true, "test_app_user should be member of test_readonly")
    }

    func testAppUserHasSelectViaInheritance() async throws {
        let rows = try await client.simpleQuery("""
            SELECT has_table_privilege('test_app_user', 'app.users', 'SELECT')
        """)
        var hasSelect: Bool?
        for try await val in rows.decode(Bool.self) { hasSelect = val }
        XCTAssertEqual(hasSelect, true, "test_app_user should inherit SELECT from test_readonly")
    }

    func testAppUserCannotInsert() async throws {
        let rows = try await client.simpleQuery("""
            SELECT has_table_privilege('test_app_user', 'app.users', 'INSERT')
        """)
        var hasInsert: Bool?
        for try await val in rows.decode(Bool.self) { hasInsert = val }
        XCTAssertEqual(hasInsert, false, "test_app_user should NOT have INSERT (only inherits readonly)")
    }

    // MARK: - Schema Usage

    func testReadonlyHasSchemaUsage() async throws {
        let rows = try await client.simpleQuery("""
            SELECT has_schema_privilege('test_readonly', 'app', 'USAGE')
        """)
        var hasUsage: Bool?
        for try await val in rows.decode(Bool.self) { hasUsage = val }
        XCTAssertEqual(hasUsage, true, "test_readonly should have USAGE on app schema")
    }

    // MARK: - Create and Drop Role via Client API

    func testCreateAndDropUser() async throws {
        let roleName = uniqueName()
        addTeardownBlock { [client = self.client!] in
            try? await client.security.dropOwned(by: roleName)
            _ = try? await client.security.dropUser(name: roleName, ifExists: true)
        }

        _ = try await client.security.createUser(
            name: roleName,
            password: "testpw123",
            createDatabase: false,
            createRole: false,
            login: true
        )

        // Verify role exists
        let rows = try await client.simpleQuery("SELECT rolname FROM pg_roles WHERE rolname = '\(roleName)'")
        var found = false
        for try await _ in rows { found = true }
        XCTAssertTrue(found, "Created role should exist")

        // Drop it
        _ = try await client.security.dropUser(name: roleName)

        // Verify gone
        let afterRows = try await client.simpleQuery("SELECT rolname FROM pg_roles WHERE rolname = '\(roleName)'")
        var afterFound = false
        for try await _ in afterRows { afterFound = true }
        XCTAssertFalse(afterFound, "Dropped role should not exist")
    }

    func testAlterUser() async throws {
        let roleName = uniqueName()
        addTeardownBlock { [client = self.client!] in
            try? await client.security.dropOwned(by: roleName)
            _ = try? await client.security.dropUser(name: roleName, ifExists: true)
        }

        _ = try await client.security.createUser(name: roleName, createDatabase: false, createRole: false, login: false)

        // Enable login
        _ = try await client.security.alterUser(name: roleName, login: true)

        let rows = try await client.simpleQuery("SELECT rolcanlogin FROM pg_roles WHERE rolname = '\(roleName)'")
        var canLogin: Bool?
        for try await val in rows.decode(Bool.self) { canLogin = val }
        XCTAssertEqual(canLogin, true, "Altered role should now have LOGIN")
    }

    // MARK: - Grant and Revoke Privileges via Client API

    func testGrantAndRevokeTablePrivileges() async throws {
        let roleName = uniqueName()
        let table = uniqueName("tbl")
        addTeardownBlock { [client = self.client!] in
            _ = try? await client.admin.dropTable(name: table, ifExists: true)
            try? await client.security.dropOwned(by: roleName)
            _ = try? await client.security.dropUser(name: roleName, ifExists: true)
        }

        _ = try await client.security.createUser(name: roleName, createDatabase: false, createRole: false, login: false)
        _ = try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            .text(name: "name")
        ])

        // Grant SELECT
        _ = try await client.security.grantPrivileges(privileges: [.select], onTable: table, to: roleName)

        let hasSelect = try await client.simpleQuery("SELECT has_table_privilege('\(roleName)', '\(table)', 'SELECT')")
        for try await val in hasSelect.decode(Bool.self) {
            XCTAssertTrue(val, "Should have SELECT after grant")
        }

        // Revoke SELECT
        _ = try await client.security.revokePrivileges(privileges: [.select], onTable: table, from: roleName)

        let afterRevoke = try await client.simpleQuery("SELECT has_table_privilege('\(roleName)', '\(table)', 'SELECT')")
        for try await val in afterRevoke.decode(Bool.self) {
            XCTAssertFalse(val, "Should NOT have SELECT after revoke")
        }
    }

    func testGrantMultiplePrivileges() async throws {
        let roleName = uniqueName()
        let table = uniqueName("tbl")
        addTeardownBlock { [client = self.client!] in
            _ = try? await client.admin.dropTable(name: table, ifExists: true)
            try? await client.security.dropOwned(by: roleName)
            _ = try? await client.security.dropUser(name: roleName, ifExists: true)
        }

        _ = try await client.security.createUser(name: roleName, createDatabase: false, createRole: false, login: false)
        _ = try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            .text(name: "name")
        ])

        _ = try await client.security.grantPrivileges(privileges: [.select, .insert, .update], onTable: table, to: roleName)

        let rows = try await client.simpleQuery("""
            SELECT
                has_table_privilege('\(roleName)', '\(table)', 'SELECT') AS sel,
                has_table_privilege('\(roleName)', '\(table)', 'INSERT') AS ins,
                has_table_privilege('\(roleName)', '\(table)', 'UPDATE') AS upd,
                has_table_privilege('\(roleName)', '\(table)', 'DELETE') AS del
        """)
        for try await (sel, ins, upd, del) in rows.decode((Bool, Bool, Bool, Bool).self) {
            XCTAssertTrue(sel)
            XCTAssertTrue(ins)
            XCTAssertTrue(upd)
            XCTAssertFalse(del, "DELETE was not granted")
        }
    }

    // MARK: - Grant and Revoke Role via Client API

    func testGrantAndRevokeRole() async throws {
        let parentRole = uniqueName("parent")
        let childRole = uniqueName("child")
        addTeardownBlock { [client = self.client!] in
            try? await client.security.dropOwned(by: childRole)
            _ = try? await client.security.dropUser(name: childRole, ifExists: true)
            try? await client.security.dropOwned(by: parentRole)
            _ = try? await client.security.dropUser(name: parentRole, ifExists: true)
        }

        _ = try await client.security.createUser(name: parentRole, createDatabase: false, createRole: false, login: false)
        _ = try await client.security.createUser(name: childRole, createDatabase: false, createRole: false, login: false)

        // Grant parentRole to childRole
        _ = try await client.security.grantRole(role: parentRole, to: childRole)

        let memberRows = try await client.simpleQuery("""
            SELECT pg_has_role('\(childRole)', '\(parentRole)', 'MEMBER')
        """)
        for try await val in memberRows.decode(Bool.self) {
            XCTAssertTrue(val, "child should be member of parent after grant")
        }

        // Revoke
        _ = try await client.security.revokeRole(role: parentRole, from: childRole)

        let afterRows = try await client.simpleQuery("""
            SELECT pg_has_role('\(childRole)', '\(parentRole)', 'MEMBER')
        """)
        for try await val in afterRows.decode(Bool.self) {
            XCTAssertFalse(val, "child should NOT be member of parent after revoke")
        }
    }

    // MARK: - Role Introspection

    func testRoleAttributeIntrospection() async throws {
        let roles = try await client.security.listRoles()
        let readwrite = roles.first { $0.name == "test_readwrite" }
        XCTAssertNotNil(readwrite, "Should find test_readwrite role")
    }

    func testRoleComment() async throws {
        let roleName = uniqueName()
        addTeardownBlock { [client = self.client!] in
            try? await client.security.dropOwned(by: roleName)
            _ = try? await client.security.dropUser(name: roleName, ifExists: true)
        }

        _ = try await client.security.createUser(name: roleName, createDatabase: false, createRole: false, login: false)
        try await client.security.setRoleComment(role: roleName, comment: "Test role for integration tests")

        let rows = try await client.simpleQuery("""
            SELECT pg_catalog.shobj_description(oid, 'pg_authid')
            FROM pg_roles WHERE rolname = '\(roleName)'
        """)
        var comment: String?
        for try await c in rows.decode(String?.self) { comment = c }
        XCTAssertEqual(comment, "Test role for integration tests")
    }

    // MARK: - Sequence Privileges

    func testReadwriteHasSequenceUsage() async throws {
        let rows = try await client.simpleQuery("""
            SELECT has_sequence_privilege('test_readwrite', s.oid, 'USAGE')
            FROM pg_class s
            JOIN pg_namespace n ON s.relnamespace = n.oid
            WHERE n.nspname = 'app' AND s.relkind = 'S'
            LIMIT 1
        """)
        var hasUsage: Bool?
        for try await val in rows.decode(Bool.self) { hasUsage = val }
        if let hasUsage = hasUsage {
            XCTAssertTrue(hasUsage, "test_readwrite should have USAGE on app sequences")
        }
    }
}
