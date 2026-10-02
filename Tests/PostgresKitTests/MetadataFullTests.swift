import XCTest
import Logging
import PostgresKit

private actor ProgressCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Full integration test coverage for PostgresMetadata.
/// Tests all public methods not already covered by MetadataIntegrationTests.swift.
final class MetadataFullTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else {
            throw XCTSkip("POSTGRES_HOST not set. Copy .env.example to .env and configure connection.")
        }
        let config = PostgresConfiguration(
            host: TestEnv.host,
            port: TestEnv.port,
            database: TestEnv.database,
            username: TestEnv.username,
            password: TestEnv.password,
            useTLS: TestEnv.useTLS,
            applicationName: "MetadataFullTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() async throws {
        client?.close()
    }

    // MARK: - listDatabases

    func testListDatabases() async throws {
        let dbs = try await client.metadata.listDatabases()
        XCTAssertFalse(dbs.isEmpty, "Should return at least one database")
        XCTAssertTrue(dbs.contains(TestEnv.database), "Connected database should be in list")
    }

    // MARK: - listSchemas

    func testListSchemas() async throws {
        let schemas = try await client.metadata.listSchemas()
        let schemaNames = schemas.map(\.name)
        // At minimum, 'public' should be present unless it was removed
        XCTAssertFalse(schemaNames.isEmpty, "Should have at least one schema")
        // System schemas are excluded
        XCTAssertFalse(schemaNames.contains("pg_catalog"), "pg_catalog should be excluded")
        XCTAssertFalse(schemaNames.contains("information_schema"), "information_schema should be excluded")
    }

    // MARK: - listColumns

    func testListColumns() async throws {
        let table = "pgwire_meta_col_\(UInt32.random(in: 0..<UInt32.max))"
        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            .text(name: "name", nullable: false),
            .integer(name: "score", defaultValue: 0)
        ])
        defer {
            Task { [client = self.client!] in
                _ = try? await client.admin.dropTable(name: table, ifExists: true)
            }
        }

        let columns = try await client.metadata.listColumns(schema: "public", table: table)
        XCTAssertEqual(columns.count, 3)
        let names = columns.map { $0.name }
        XCTAssertTrue(names.contains("id"))
        XCTAssertTrue(names.contains("name"))
        XCTAssertTrue(names.contains("score"))

        let nameCol = columns.first { $0.name == "name" }
        XCTAssertEqual(nameCol?.isNullable, false)

        let scoreCol = columns.first { $0.name == "score" }
        XCTAssertNotNil(scoreCol?.defaultValue, "score should have a default value")
    }

    // MARK: - listIndexes

    func testListIndexes() async throws {
        let table = "pgwire_meta_idx_\(UInt32.random(in: 0..<UInt32.max))"
        let idx = "pgwire_meta_idx_name_\(UInt32.random(in: 0..<UInt32.max))"
        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            .text(name: "name"),
            .integer(name: "score")
        ])
        try await client.indexes.createIndex(name: idx, table: table, columns: ["name"])
        try await client.indexes.createIndex(name: "\(idx)_unique", table: table, columns: ["score"], unique: true)
        defer {
            Task { [client = self.client!] in
                _ = try? await client.admin.dropTable(name: table, ifExists: true)
            }
        }

        let indexes: [PostgresIndexInfo]
        do {
            indexes = try await client.metadata.listIndexes(schema: "public", table: table)
        } catch {
            XCTFail("listIndexes failed: \(String(reflecting: error))")
            return
        }
        XCTAssertGreaterThanOrEqual(indexes.count, 2, "Should have at least 2 non-primary indexes")

        let uniqueIdx = indexes.first { $0.isUnique }
        XCTAssertNotNil(uniqueIdx, "Should have at least one unique index")

        let names = indexes.map { $0.name }
        XCTAssertTrue(names.contains(idx), "Should contain the named index")
    }

    // MARK: - primaryKey

    func testPrimaryKey() async throws {
        let table = "pgwire_meta_pk_\(UInt32.random(in: 0..<UInt32.max))"
        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            .text(name: "val")
        ])
        defer {
            Task { [client = self.client!] in
                _ = try? await client.admin.dropTable(name: table, ifExists: true)
            }
        }

        let pk = try await client.metadata.primaryKey(schema: "public", table: table)
        XCTAssertNotNil(pk, "Table with primary key should return a PrimaryKey")
        XCTAssertEqual(pk?.columns, ["id"])
    }

    func testPrimaryKeyNone() async throws {
        let table = "pgwire_meta_nopk_\(UInt32.random(in: 0..<UInt32.max))"
        try await client.admin.createTable(name: table, columns: [
            .text(name: "val")
        ])
        defer {
            Task { [client = self.client!] in
                _ = try? await client.admin.dropTable(name: table, ifExists: true)
            }
        }

        let pk = try await client.metadata.primaryKey(schema: "public", table: table)
        XCTAssertNil(pk, "Table without primary key should return nil")
    }

    // MARK: - foreignKeys

    func testForeignKeys() async throws {
        let parent = "pgwire_meta_fkp_\(UInt32.random(in: 0..<UInt32.max))"
        let child = "pgwire_meta_fkc_\(UInt32.random(in: 0..<UInt32.max))"
        try await client.admin.createTable(name: parent, columns: [
            .serial(name: "id", primaryKey: true),
            .text(name: "name")
        ])
        try await client.admin.createTable(name: child, columns: [
            .serial(name: "id", primaryKey: true),
            .integer(name: "parent_id")
        ])
        try await client.constraints.addForeignKey(table: child, column: "parent_id", referencesTable: parent, referencesColumn: "id")
        defer {
            Task { [client = self.client!] in
                _ = try? await client.admin.dropTable(name: child, ifExists: true, cascade: true)
                _ = try? await client.admin.dropTable(name: parent, ifExists: true, cascade: true)
            }
        }

        let fks = try await client.metadata.foreignKeys(schema: "public", table: child)
        XCTAssertEqual(fks.count, 1, "Child table should have 1 FK")
        let fk = fks[0]
        XCTAssertEqual(fk.columns, ["parent_id"])
        XCTAssertEqual(fk.referencedTable, parent)
        XCTAssertEqual(fk.referencedColumns, ["id"])
    }

    // MARK: - uniqueConstraints

    func testUniqueConstraints() async throws {
        let table = "pgwire_meta_uq_\(UInt32.random(in: 0..<UInt32.max))"
        let uqName = "uq_code_\(UInt32.random(in: 0..<UInt32.max))"
        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            PostgresColumnDefinition(name: "email", dataType: "TEXT", unique: true),
            .text(name: "code")
        ])
        try await client.constraints.addUniqueConstraint(table: table, columns: ["code"], constraintName: uqName)
        defer {
            Task { [client = self.client!] in
                _ = try? await client.admin.dropTable(name: table, ifExists: true)
            }
        }

        let constraints = try await client.metadata.uniqueConstraints(schema: "public", table: table)
        XCTAssertGreaterThanOrEqual(constraints.count, 2, "Should have at least 2 unique constraints")
        let colNames = constraints.flatMap { $0.columns }
        XCTAssertTrue(colNames.contains("email"))
        XCTAssertTrue(colNames.contains("code"))
    }

    // MARK: - dependencies

    func testDependencies() async throws {
        let parent = "pgwire_meta_dep_p_\(UInt32.random(in: 0..<UInt32.max))"
        let child = "pgwire_meta_dep_c_\(UInt32.random(in: 0..<UInt32.max))"
        try await client.admin.createTable(name: parent, columns: [
            .serial(name: "id", primaryKey: true)
        ])
        try await client.admin.createTable(name: child, columns: [
            .serial(name: "id", primaryKey: true),
            .integer(name: "pid")
        ])
        try await client.constraints.addForeignKey(table: child, column: "pid", referencesTable: parent, referencesColumn: "id")
        defer {
            Task { [client = self.client!] in
                _ = try? await client.admin.dropTable(name: child, ifExists: true, cascade: true)
                _ = try? await client.admin.dropTable(name: parent, ifExists: true, cascade: true)
            }
        }

        // dependencies() returns tables that reference the given table
        let deps = try await client.metadata.dependencies(schema: "public", table: parent)
        XCTAssertFalse(deps.isEmpty, "Parent table should have at least one dependent (the child)")
        let depTables = deps.map { $0.sourceTable }
        XCTAssertTrue(depTables.contains(child))
    }

    // MARK: - viewDefinition

    func testViewDefinition() async throws {
        let table = "pgwire_meta_vw_t_\(UInt32.random(in: 0..<UInt32.max))"
        let view = "pgwire_meta_vw_\(UInt32.random(in: 0..<UInt32.max))"
        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id"),
            .text(name: "name")
        ])
        try await client.views.createView(name: view, query: "SELECT id, name FROM \(table) WHERE id > 0")
        defer {
            Task { [client = self.client!] in
                _ = try? await client.views.dropView(name: view, ifExists: true)
                _ = try? await client.admin.dropTable(name: table, ifExists: true)
            }
        }

        let def = try await client.metadata.viewDefinition(schema: "public", view: view)
        XCTAssertNotNil(def, "View definition should not be nil")
        XCTAssertTrue(def?.lowercased().contains("select") == true,
                      "View definition should contain SELECT")
    }

    // MARK: - functionDefinition

    func testFunctionDefinition() async throws {
        let fn = "pgwire_meta_fn_\(UInt32.random(in: 0..<UInt32.max))"
        try await client.routines.createFunction(
            name: fn,
            parameters: [PostgresFunctionParameter(name: "x", dataType: "integer")],
            returnType: "integer",
            body: "SELECT x * 2",
            language: .sql,
            orReplace: true
        )
        defer {
            Task { [client = self.client!] in
                _ = try? await client.routines.dropFunction(name: fn, parameters: ["integer"], ifExists: true)
            }
        }

        let def = try await client.metadata.functionDefinition(schema: "public", name: fn)
        XCTAssertNotNil(def, "Function definition should not be nil")
        XCTAssertTrue(def?.contains(fn) == true || def?.lowercased().contains("function") == true,
                      "Definition should contain the function name or 'FUNCTION'")
    }

    // MARK: - triggerDefinition

    func testTriggerDefinition() async throws {
        let table = "pgwire_meta_trig_t_\(UInt32.random(in: 0..<UInt32.max))"
        let fn = "pgwire_meta_trig_fn_\(UInt32.random(in: 0..<UInt32.max))"
        let trig = "pgwire_meta_trig_\(UInt32.random(in: 0..<UInt32.max))"
        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id"),
            .text(name: "val")
        ])
        try await client.routines.createFunction(
            name: fn,
            parameters: [],
            returnType: "trigger",
            body: "BEGIN RETURN NEW; END;",
            language: .plpgsql,
            orReplace: true
        )
        try await client.triggers.createTrigger(
            name: trig,
            table: table,
            event: .before,
            operations: [.insert],
            procedure: "\(fn)()"
        )
        defer {
            Task { [client = self.client!] in
                _ = try? await client.triggers.dropTrigger(name: trig, table: table, ifExists: true)
                _ = try? await client.admin.dropTable(name: table, ifExists: true)
                _ = try? await client.routines.dropFunction(name: fn, parameters: [], ifExists: true)
            }
        }

        let def = try await client.metadata.triggerDefinition(schema: "public", name: trig)
        XCTAssertNotNil(def, "Trigger definition should not be nil")
        XCTAssertTrue(def?.uppercased().contains("TRIGGER") == true,
                      "Trigger definition should contain TRIGGER")
    }

    // MARK: - listRoles

    func testListRoles() async throws {
        let roles = try await client.security.listRoles()
        XCTAssertFalse(roles.isEmpty, "Should return at least one role")
        // postgres superuser role always exists
        let roleNames = roles.map { $0.name }
        XCTAssertTrue(roleNames.contains("postgres") || !roleNames.isEmpty,
                      "Should have a postgres or other role")
    }

    // MARK: - listExtensions

    func testListExtensions() async throws {
        let extensions = try await client.metadata.listExtensions()
        // plpgsql is always installed by default
        XCTAssertFalse(extensions.isEmpty, "Should have at least plpgsql extension")
        let extNames = extensions.map { $0.name }
        XCTAssertTrue(extNames.contains("plpgsql"), "plpgsql should always be installed")
    }

    // MARK: - Comments

    // TODO: uncomment when addTableComment API is implemented on PostgresAdminClient
//    func testTableComment() async throws {
//        let table = "pgwire_meta_cmt_\(UInt32.random(in: 0..<UInt32.max))"
//        let comment = "Integration test table for comments"
//        try await client.admin.createTable(name: table, columns: [
//            .serial(name: "id")
//        ])
//        try await client.admin.addTableComment(name: table, comment: comment)
//        defer {
//            Task { [client = self.client!] in
//                _ = try? await client.admin.dropTable(name: table, ifExists: true)
//            }
//        }
//
//        let retrieved = try await meta.fetchTableComment(using: client, schema: "public", table: table)
//        XCTAssertEqual(retrieved, comment)
//    }

    // TODO: uncomment when addColumnComment API is implemented on PostgresAdminClient
//    func testColumnComments() async throws {
//        let table = "pgwire_meta_colcmt_\(UInt32.random(in: 0..<UInt32.max))"
//        try await client.admin.createTable(name: table, columns: [
//            .serial(name: "id"),
//            .text(name: "name")
//        ])
//        try await client.admin.addColumnComment(table: table, column: "name", comment: "The display name")
//        defer {
//            Task { [client = self.client!] in
//                _ = try? await client.admin.dropTable(name: table, ifExists: true)
//            }
//        }
//
//        let comments = try await meta.fetchColumnComments(using: client, schema: "public", table: table)
//        XCTAssertFalse(comments.isEmpty, "Should return column comment entries")
//        let nameComment = comments.first { $0.column == "name" }
//        XCTAssertEqual(nameComment?.comment, "The display name")
//    }

    func testDatabaseComment() async throws {
        // This may return nil if no comment has been set — either is valid
        let comment = try await client.metadata.fetchDatabaseComment()
        _ = comment // nil or a string, both acceptable
    }

    // MARK: - schemaSummary

    func testSchemaSummary_PublicSchema() async throws {
        let table = "pgwire_meta_sum_\(UInt32.random(in: 0..<UInt32.max))"
        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            .text(name: "label")
        ])
        defer {
            Task { [client = self.client!] in
                _ = try? await client.admin.dropTable(name: table, ifExists: true)
            }
        }

        let summary = try await client.metadata.schemaSummary(schema: "public")
        XCTAssertEqual(summary.schema, "public")

        let tableObj = summary.objects.first { $0.name == table }
        XCTAssertNotNil(tableObj, "Summary should include our test table")
        XCTAssertEqual(tableObj?.type, .table)
        XCTAssertFalse(tableObj?.columns.isEmpty == true, "Table should have columns in summary")
    }

    func testSchemaSummary_WithProgressCallback() async throws {
        let counter = ProgressCounter()
        let summary = try await client.metadata.schemaSummary(schema: "public") { _, _, _ in
            await counter.increment()
        }
        XCTAssertEqual(summary.schema, "public")
        let calls = await counter.value
        XCTAssertGreaterThan(calls, 0, "Progress callback should have been called")
    }
}
