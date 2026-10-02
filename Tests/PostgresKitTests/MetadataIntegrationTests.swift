import PostgresKit
import XCTest
import Logging

final class MetadataIntegrationTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "MetadataIntegrationTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    private func uniqueName(_ prefix: String = "meta") -> String {
        "\(prefix)_\(UInt32.random(in: 0..<UInt32.max))"
    }

    // MARK: - Schema Discovery

    func testListSchemas() async throws {
        let schemas = try await client.metadata.listSchemas()
        let schemaNames = schemas.map(\.name)
        XCTAssertTrue(schemaNames.contains("public"), "Should contain public schema")
        // Note: listSchemas() intentionally filters out information_schema and pg_ schemas
    }

    func testListSchemasIncludesSampleDataSchemas() async throws {
        let schemas = try await client.metadata.listSchemas()
        let schemaNames = schemas.map(\.name)
        XCTAssertTrue(schemaNames.contains("app"), "Should contain app schema from SampleData")
        XCTAssertTrue(schemaNames.contains("audit"), "Should contain audit schema from SampleData")
        XCTAssertTrue(schemaNames.contains("archive"), "Should contain archive schema from SampleData")
    }

    // MARK: - Tables and Views

    func testListTablesAndViewsInPublicSchema() async throws {
        let objects = try await client.metadata.listTablesAndViews(schema: "public")
        let names = objects.map { $0.name }
        // SampleData creates type tables in public schema
        XCTAssertTrue(names.contains("numeric_types"), "Should find numeric_types table")
        XCTAssertTrue(names.contains("text_types"), "Should find text_types table")
    }

    func testListTablesAndViewsInAppSchema() async throws {
        let objects = try await client.metadata.listTablesAndViews(schema: "app")
        let names = objects.map { $0.name }
        XCTAssertTrue(names.contains("users"), "Should find app.users table")
        XCTAssertTrue(names.contains("posts"), "Should find app.posts table")
    }

    // MARK: - Columns

    func testListColumnsForTable() async throws {
        let table = uniqueName()
        let refTable = uniqueName("ref")
        defer { Task { [client = self.client!] in
            _ = try? await client.admin.dropTable(name: table, ifExists: true, cascade: true)
            _ = try? await client.admin.dropTable(name: refTable, ifExists: true, cascade: true)
        }}

        try await client.admin.createTable(name: refTable, columns: [
            PostgresColumnDefinition(name: "id", dataType: "INT", primaryKey: true),
            .text(name: "description")
        ])
        try await client.admin.createTable(name: table, columns: [
            PostgresColumnDefinition(name: "id", dataType: "INT", primaryKey: true),
            .text(name: "name"),
            .integer(name: "ref_id")
        ])
        try await client.constraints.addForeignKey(table: table, column: "ref_id", referencesTable: refTable, referencesColumn: "id", constraintName: "fk_\(table)")

        let byTable = try await client.metadata.columnsByTable(schema: "public")
        guard let details = byTable[table] else {
            return XCTFail("Expected details for table \(table)")
        }

        let names = Set(details.map { $0.name })
        XCTAssertTrue(names.contains("id"))
        XCTAssertTrue(names.contains("name"))
        XCTAssertTrue(names.contains("ref_id"))
        XCTAssertTrue(details.first(where: { $0.name == "id" })?.isPrimaryKey == true)
        XCTAssertNotNil(details.first(where: { $0.name == "ref_id" })?.foreignKey)
    }

    func testListColumnsForSampleDataTable() async throws {
        let columns = try await client.metadata.listColumns(schema: "app", table: "users")
        let names = columns.map { $0.name }
        XCTAssertTrue(names.contains("id"), "Should have id column")
        XCTAssertTrue(names.contains("username"), "Should have username column")
        XCTAssertTrue(names.contains("email"), "Should have email column")
    }

    // MARK: - Foreign Key Detection

    func testForeignKeyDetection() async throws {
        let fks = try await client.metadata.foreignKeys(schema: "app", table: "posts")
        XCTAssertFalse(fks.isEmpty, "app.posts should have foreign keys")
        // posts references users
        let userFK = fks.first { $0.referencedTable == "users" }
        XCTAssertNotNil(userFK, "Should have FK referencing users")
    }

    // MARK: - Primary Key

    func testPrimaryKeyDetection() async throws {
        let pk = try await client.metadata.primaryKey(schema: "app", table: "users")
        XCTAssertNotNil(pk, "app.users should have a primary key")
        XCTAssertTrue(pk?.columns.contains("id") == true)
    }

    // MARK: - Index Introspection

    func testListIndexes() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            .text(name: "name"),
            .text(name: "email")
        ])
        try await client.indexes.createIndex(name: "idx_\(table)_name", table: table, columns: ["name"])
        try await client.indexes.createIndex(name: "idx_\(table)_email", table: table, columns: ["email"], unique: true)

        let indexes = try await client.metadata.listIndexes(schema: "public", table: table)
        XCTAssertGreaterThanOrEqual(indexes.count, 2, "Should have at least PK index + name index + email index")

        let nameIdx = indexes.first { $0.name.contains("name") }
        XCTAssertNotNil(nameIdx, "Should have name index")

        let emailIdx = indexes.first { $0.name.contains("email") }
        XCTAssertNotNil(emailIdx, "Should have email index")
    }

    // MARK: - Unique Constraints

    func testUniqueConstraints() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in _ = try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            PostgresColumnDefinition(name: "code", dataType: "TEXT", unique: true),
            .text(name: "email")
        ])
        try await client.constraints.addUniqueConstraint(table: table, columns: ["email"], constraintName: "uq_\(table)_email")

        let constraints = try await client.metadata.uniqueConstraints(schema: "public", table: table)
        XCTAssertGreaterThanOrEqual(constraints.count, 2, "Should have at least 2 unique constraints (code + email)")
    }

    // MARK: - View Definition

    func testViewDefinition() async throws {
        let def = try await client.metadata.viewDefinition(schema: "app", view: "active_users")
        XCTAssertNotNil(def, "Should find active_users view definition")
        if let def = def {
            XCTAssertTrue(def.lowercased().contains("select"), "View definition should contain SELECT")
        }
    }

    // MARK: - Databases

    func testListDatabases() async throws {
        let databases = try await client.metadata.listDatabases()
        XCTAssertFalse(databases.isEmpty, "Should list at least one database")
        XCTAssertTrue(databases.contains(TestEnv.database), "Should contain the test database")
    }

    // MARK: - Extensions

    func testListExtensions() async throws {
        let extensions = try await client.metadata.listExtensions()
        let names = extensions.map { $0.name }
        XCTAssertTrue(names.contains("plpgsql"), "Should have plpgsql extension")
        // SampleData installs these
        XCTAssertTrue(names.contains("hstore"), "Should have hstore extension from SampleData")
    }

    // MARK: - Roles

    func testListRoles() async throws {
        let roles = try await client.security.listRoles()
        XCTAssertFalse(roles.isEmpty, "Should list at least one role")
        // SampleData creates test roles
        let roleNames = roles.map { $0.name }
        XCTAssertTrue(roleNames.contains("test_readonly"), "Should have test_readonly role from SampleData")
    }

    // MARK: - Schema Summary

    func testSchemaSummary() async throws {
        let summary = try await client.metadata.schemaSummary(schema: "app")
        XCTAssertFalse(summary.objects.filter { $0.type == .table }.isEmpty, "App schema should have tables")
    }
}
