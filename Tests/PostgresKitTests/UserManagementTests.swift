import XCTest
import Logging
@testable import PostgresKit

final class UserManagementTests: PostgresKitTestCase {

    private var client: PostgresKit.PostgresClient!
    private var testLogger: Logger!

    override func setUp() async throws {
        guard TestEnv.isConfigured else {
            throw XCTSkip("POSTGRES_HOST not set. Copy .env.example to .env and configure connection.")
        }
        try await super.setUp()
        testLogger = Logger(label: "postgres.wire.tests")

        let config = PostgresConfiguration(
            host: TestEnv.host,
            port: TestEnv.port,
            database: TestEnv.database,
            username: TestEnv.username,
            password: TestEnv.password,
            useTLS: TestEnv.useTLS,
            applicationName: "UserManagementTests"
        )

        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: testLogger)
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    // MARK: - Helpers

    private let suffix = UInt32.random(in: 0..<UInt32.max)

    private func dropRoleIfExists(_ name: String) async {
        _ = try? await client.security.dropRole(name: name, ifExists: true)
    }

    private func dropUserIfExists(_ name: String) async {
        _ = try? await client.security.dropUser(name: name, ifExists: true)
    }

    // MARK: - Role/User Management

    func testCreateAndDropRoles() async throws {
        let s = suffix
        let roleNames = ["reader_\(s)", "writer_\(s)", "admin_\(s)"]
        // Pre-clean in case of leftovers
        for r in roleNames { await dropRoleIfExists(r) }
        let superName = "super_\(s)"
        await dropRoleIfExists(superName)

        addTeardownBlock { [client] in
            for r in roleNames {
                try? await client?.security.dropOwned(by: r)
                _ = try? await client?.security.dropRole(name: r, ifExists: true)
            }
            try? await client?.security.dropOwned(by: superName)
            _ = try? await client?.security.dropRole(name: superName, ifExists: true)
        }

        let allRoles = roleNames + [superName]

        for roleName in roleNames {
            try await client.security.createRole(name: roleName, password: "test123", login: true)
        }
        try await client.security.createRole(
            name: superName,
            password: "superpass123",
            superuser: true,
            createDatabase: true,
            createRole: true,
            login: true
        )

        // Verify roles exist
        let nameList = allRoles.joined(separator: "','")
        let verifyRows = try await client.simpleQuery("""
            SELECT rolname FROM pg_roles WHERE rolname = ANY(ARRAY['\(nameList)'])
        """)
        var verified: [String] = []
        for try await name in verifyRows.decode(String.self) { verified.append(name) }
        XCTAssertEqual(verified.count, allRoles.count, "All created roles should be verifiable")

        // Drop and verify
        for r in allRoles {
            try await client.security.dropRole(name: r, ifExists: true)
        }

        let afterRows = try await client.simpleQuery("""
            SELECT rolname FROM pg_roles WHERE rolname = ANY(ARRAY['\(nameList)'])
        """)
        var remaining: [String] = []
        for try await name in afterRows.decode(String.self) { remaining.append(name) }
        XCTAssertEqual(remaining.count, 0, "All test roles should be dropped")
    }

    // MARK: - User Attributes

    func testUserAttributes() async throws {
        let userName = "attr_user_\(suffix)"
        await dropUserIfExists(userName)
        let renamedName = "renamed_\(suffix)"
        await dropUserIfExists(renamedName)

        addTeardownBlock { [client] in
            try? await client?.security.dropOwned(by: renamedName)
            _ = try? await client?.security.dropUser(name: renamedName, ifExists: true)
            try? await client?.security.dropOwned(by: userName)
            _ = try? await client?.security.dropUser(name: userName, ifExists: true)
        }

        try await client.security.createRole(name: userName, password: "attrpass123", login: true, connectionLimit: 5)
        try await client.security.alterUser(name: userName, connectionLimit: 10)
        try await client.security.alterUser(name: userName, rename: renamedName)
        try await client.security.alterUser(name: renamedName, validUntil: "infinity")

        let userRows = try await client.simpleQuery("""
            SELECT rolname, rolcanlogin FROM pg_roles WHERE rolname = '\(renamedName)'
        """)
        var found = false
        for try await (name, canLogin) in userRows.decode((String, Bool).self) {
            XCTAssertEqual(name, renamedName)
            XCTAssertTrue(canLogin)
            found = true
        }
        XCTAssertTrue(found, "Should find the renamed user")
    }

    // MARK: - Role Membership

    func testRoleMembership() async throws {
        let s = suffix
        let deptEng = "dept_eng_\(s)"
        let deptSales = "dept_sales_\(s)"
        let john = "john_\(s)"
        let jane = "jane_\(s)"
        let bob = "bob_\(s)"
        let allNames = [john, jane, bob, deptEng, deptSales]

        for n in allNames { await dropRoleIfExists(n) }

        addTeardownBlock { [client] in
            for n in allNames {
                try? await client?.security.dropOwned(by: n)
                _ = try? await client?.security.dropRole(name: n, ifExists: true)
            }
        }

        try await client.security.createRole(name: deptEng)
        try await client.security.createRole(name: deptSales)
        try await client.security.createUser(name: john, password: "pass123")
        try await client.security.createUser(name: jane, password: "pass123")
        try await client.security.createUser(name: bob, password: "pass123")

        try await client.security.grantRole(role: deptEng, to: john)
        try await client.security.grantRole(role: deptSales, to: jane)
        try await client.security.grantRole(role: deptEng, to: bob)
        try await client.security.grantRole(role: deptSales, to: bob)

        let membershipRows = try await client.simpleQuery("""
            SELECT ur1.rolname AS user_role, ur2.rolname AS role_membership
            FROM pg_roles ur1
            JOIN pg_auth_members pam ON ur1.oid = pam.member
            JOIN pg_roles ur2 ON pam.roleid = ur2.oid
            WHERE ur1.rolname IN ('\(john)', '\(jane)', '\(bob)')
            ORDER BY user_role, role_membership
        """)

        var memberships: [(String, String)] = []
        for try await (user, role) in membershipRows.decode((String, String).self) {
            memberships.append((user, role))
        }

        XCTAssertGreaterThan(memberships.count, 0, "Should have role memberships")
        // bob should have 2 memberships (eng + sales)
        let bobMemberships = memberships.filter { $0.0 == bob }
        XCTAssertEqual(bobMemberships.count, 2, "Bob should have 2 role memberships")
    }

    // MARK: - Default Privileges

    func testDefaultPrivileges() async throws {
        let s = suffix
        let roleName = "priv_role_\(s)"
        let userName = "priv_user_\(s)"
        let schemaName = "priv_schema_\(s)"

        await dropRoleIfExists(userName)
        await dropRoleIfExists(roleName)

        addTeardownBlock { [client] in
            _ = try? await client?.admin.dropSchema(name: schemaName, ifExists: true, cascade: true)
            try? await client?.security.dropOwned(by: userName)
            _ = try? await client?.security.dropUser(name: userName, ifExists: true)
            try? await client?.security.dropOwned(by: roleName)
            _ = try? await client?.security.dropRole(name: roleName, ifExists: true)
        }

        try await client.security.createRole(name: roleName)
        try await client.security.createUser(name: userName, password: "test123")
        try await client.security.grantRole(role: roleName, to: userName)
        try await client.admin.createSchema(name: schemaName)
        try await client.security.grantSchemaPrivileges(privileges: [.usage], onSchema: schemaName, to: roleName)

        try await client.security.alterDefaultPrivileges(
            schema: schemaName,
            grant: [.select, .insert, .update, .delete],
            onObjectType: .tables,
            to: roleName
        )

        try await client.admin.createTable(
            name: "\(schemaName).test_tbl",
            columns: [.serial(name: "id", primaryKey: true), .text(name: "name")]
        )

        let aclRows = try await client.simpleQuery("""
            SELECT privilege_type
            FROM information_schema.role_table_grants
            WHERE table_schema = '\(schemaName)' AND table_name = 'test_tbl' AND grantee = '\(roleName)'
            ORDER BY privilege_type
        """)

        var privileges: [String] = []
        for try await priv in aclRows.decode(String.self) {
            privileges.append(priv)
        }

        XCTAssertGreaterThan(privileges.count, 0, "Should have default table privileges")
    }

    // MARK: - Row Level Security

    func testRowLevelSecurity() async throws {
        let s = suffix
        let table = "rls_test_\(s)"
        let alice = "alice_\(s)"
        let bob = "bob_\(s)"

        await dropUserIfExists(alice)
        await dropUserIfExists(bob)

        addTeardownBlock { [client] in
            _ = try? await client?.admin.dropTable(name: table, ifExists: true)
            try? await client?.security.dropOwned(by: alice)
            _ = try? await client?.security.dropUser(name: alice, ifExists: true)
            try? await client?.security.dropOwned(by: bob)
            _ = try? await client?.security.dropUser(name: bob, ifExists: true)
        }

        try await client.admin.createTable(name: table, columns: [
            PostgresColumnDefinition(name: "id", dataType: "SERIAL", primaryKey: true),
            PostgresColumnDefinition(name: "owner", dataType: "TEXT"),
            PostgresColumnDefinition(name: "category", dataType: "TEXT"),
            PostgresColumnDefinition(name: "data", dataType: "TEXT"),
        ])

        try await client.security.createUser(name: alice, password: "alice123")
        try await client.security.createUser(name: bob, password: "bob123")

        try await client.bulk.insert(into: table, columns: ["owner", "category", "data"], values: [
            ["alice", "personal", "Alice personal data"],
            ["bob", "work", "Bob work data"],
            ["alice", "public", "Alice public data"],
            ["bob", "public", "Bob public data"]
        ])

        try await client.security.enableRowLevelSecurity(table: table)

        try await client.security.createPolicy(
            name: "alice_policy_\(s)",
            table: table,
            to: [alice],
            using: "owner = 'alice' OR category = 'public'"
        )

        try await client.security.createPolicy(
            name: "bob_policy_\(s)",
            table: table,
            to: [bob],
            using: "owner = 'bob' OR category = 'public'"
        )

        // Verify policies exist
        let policyRows = try await client.simpleQuery("""
            SELECT policyname, cmd FROM pg_policies WHERE tablename = '\(table)' ORDER BY policyname
        """)

        var policies: [String] = []
        for try await (name, _) in policyRows.decode((String, String).self) {
            policies.append(name)
        }

        XCTAssertEqual(policies.count, 2, "Should have 2 RLS policies")

        // Verify data count (as superuser, sees all rows)
        let countRows = try await client.simpleQuery("SELECT COUNT(*)::text FROM \(table)")
        var totalCount = 0
        for try await countStr in countRows.decode(String.self) {
            totalCount = Int(countStr) ?? 0
        }
        XCTAssertEqual(totalCount, 4, "Should have 4 rows in test data")
    }
}
