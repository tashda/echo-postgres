import XCTest
import Logging
@testable import PostgresKit

/// Integration tests for ALTER operations on advanced PostgreSQL objects:
/// domains, composite types, collations, tablespaces, event triggers,
/// aggregates, languages, FTS configurations, and rules.
final class AdvancedObjectAlterTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!
    /// Server-wide objects a test made, dropped in tearDown before the client closes.
    private var tablespacesToDrop: [String] = []

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
            applicationName: "AdvancedObjectAlterTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))

        // Ensure the 'app' schema exists for SET SCHEMA tests
        _ = try? await client.admin.createSchema(name: "app", ifNotExists: true)
    }

    override func tearDown() async throws {
        for name in tablespacesToDrop { _ = try? await client?.admin.dropTablespace(name: name, ifExists: true) }
        tablespacesToDrop = []
        client?.close()
    }

    private func uniqueName(_ prefix: String = "alt") -> String {
        "\(prefix)_\(UInt32.random(in: 0..<UInt32.max))"
    }

    // MARK: - Domain: Rename, Owner, Schema

    func testDomainRenameOwnerSchema() async throws {
        let name = uniqueName("dom")
        let newName = uniqueName("dom_ren")
        defer { Task { [client = self.client!] in
            _ = try? await client.types.dropDomain(name: newName, ifExists: true, cascade: true, schema: "app")
            _ = try? await client.types.dropDomain(name: newName, ifExists: true, cascade: true, schema: "public")
            _ = try? await client.types.dropDomain(name: name, ifExists: true, cascade: true, schema: "public")
        }}

        // Create
        try await client.types.createDomain(name: name, dataType: "text", schema: "public")

        // Verify creation
        var domains = try await client.metadata.listDomains(schema: "public")
        XCTAssertTrue(domains.contains(where: { $0.name == name }), "Domain '\(name)' should exist after creation")

        // Rename
        try await client.types.alterDomainRename(name: name, newName: newName, schema: "public")
        domains = try await client.metadata.listDomains(schema: "public")
        XCTAssertTrue(domains.contains(where: { $0.name == newName }), "Domain should be renamed to '\(newName)'")
        XCTAssertFalse(domains.contains(where: { $0.name == name }), "Old domain name '\(name)' should not exist")

        // Change owner
        try await client.types.alterDomainOwner(name: newName, newOwner: "postgres", schema: "public")
        // No error means success — owner change is verified by not throwing

        // Change schema
        try await client.types.alterDomainSetSchema(name: newName, newSchema: "app", schema: "public")
        let publicDomains = try await client.metadata.listDomains(schema: "public")
        XCTAssertFalse(publicDomains.contains(where: { $0.name == newName }), "Domain should no longer be in 'public'")
        let appDomains = try await client.metadata.listDomains(schema: "app")
        XCTAssertTrue(appDomains.contains(where: { $0.name == newName }), "Domain should now be in 'app'")
    }

    // MARK: - Composite Type: Rename, Owner, Schema

    func testCompositeTypeRenameOwnerSchema() async throws {
        let name = uniqueName("comp")
        let newName = uniqueName("comp_ren")
        defer { Task { [client = self.client!] in
            _ = try? await client.types.dropCompositeType(name: newName, ifExists: true, cascade: true, schema: "app")
            _ = try? await client.types.dropCompositeType(name: newName, ifExists: true, cascade: true, schema: "public")
            _ = try? await client.types.dropCompositeType(name: name, ifExists: true, cascade: true, schema: "public")
        }}

        // Create
        try await client.types.createCompositeType(
            name: name,
            attributes: [("street", "text"), ("city", "text"), ("zip", "text")],
            schema: "public"
        )

        // Verify creation
        var types = try await client.metadata.listCompositeTypes(schema: "public")
        XCTAssertTrue(types.contains(where: { $0.name == name }), "Composite type '\(name)' should exist")

        // Rename
        try await client.types.alterTypeRename(name: name, newName: newName, schema: "public")
        types = try await client.metadata.listCompositeTypes(schema: "public")
        XCTAssertTrue(types.contains(where: { $0.name == newName }), "Type should be renamed to '\(newName)'")
        XCTAssertFalse(types.contains(where: { $0.name == name }), "Old type name '\(name)' should not exist")

        // Change owner
        try await client.types.alterTypeOwner(name: newName, newOwner: "postgres", schema: "public")

        // Change schema
        try await client.types.alterTypeSetSchema(name: newName, newSchema: "app", schema: "public")
        let publicTypes = try await client.metadata.listCompositeTypes(schema: "public")
        XCTAssertFalse(publicTypes.contains(where: { $0.name == newName }), "Type should no longer be in 'public'")
        let appTypes = try await client.metadata.listCompositeTypes(schema: "app")
        XCTAssertTrue(appTypes.contains(where: { $0.name == newName }), "Type should now be in 'app'")
    }

    // MARK: - Collation: Rename, Owner, Schema

    func testCollationRenameOwnerSchema() async throws {
        let name = uniqueName("coll")
        let newName = uniqueName("coll_ren")
        defer { Task { [client = self.client!] in
            _ = try? await client.admin.dropCollation(name: newName, ifExists: true, cascade: true, schema: "app")
            _ = try? await client.admin.dropCollation(name: newName, ifExists: true, cascade: true, schema: "public")
            _ = try? await client.admin.dropCollation(name: name, ifExists: true, cascade: true, schema: "public")
        }}

        // Create
        try await client.admin.createCollation(
            name: name,
            locale: "en_US.utf8",
            provider: "libc",
            schema: "public"
        )

        // Verify creation
        var collations = try await client.metadata.listCollations(schema: "public")
        XCTAssertTrue(collations.contains(where: { $0.name == name }), "Collation '\(name)' should exist")

        // Rename
        try await client.admin.alterCollationRename(name: name, newName: newName, schema: "public")
        collations = try await client.metadata.listCollations(schema: "public")
        XCTAssertTrue(collations.contains(where: { $0.name == newName }), "Collation should be renamed to '\(newName)'")
        XCTAssertFalse(collations.contains(where: { $0.name == name }), "Old collation name '\(name)' should not exist")

        // Change owner
        try await client.admin.alterCollationOwner(name: newName, newOwner: "postgres", schema: "public")

        // Change schema
        try await client.admin.alterCollationSetSchema(name: newName, newSchema: "app", schema: "public")
        let publicCollations = try await client.metadata.listCollations(schema: "public")
        XCTAssertFalse(publicCollations.contains(where: { $0.name == newName }), "Collation should no longer be in 'public'")
        let appCollations = try await client.metadata.listCollations(schema: "app")
        XCTAssertTrue(appCollations.contains(where: { $0.name == newName }), "Collation should now be in 'app'")
    }

    // MARK: - Tablespace: Rename, Owner

    func testTablespaceRenameOwner() async throws {
        // Tablespace creation requires a real directory accessible by the postgres server process.
        // In Docker CI environments this is typically not possible, so skip.
        let isCI = ProcessInfo.processInfo.environment["CI"] != nil
        if isCI {
            throw XCTSkip("Tablespace tests require a real directory path on the Postgres server — skipping on CI")
        }

        // Attempt to create a temp directory the Postgres server can access.
        // This works when running locally with a native Postgres installation.
        let tsDir = "/tmp/pgwire_test_ts_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try? await client.simpleQuery("SELECT pg_catalog.pg_file_write('/dev/null', '', false)")
        // Create the directory via shell — only works for local Postgres
        let fm = FileManager.default
        try fm.createDirectory(atPath: tsDir, withIntermediateDirectories: true)
        // Make it world-writable so the postgres user can use it
        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: tsDir)

        let name = uniqueName("ts")
        let newName = uniqueName("ts_ren")
        tablespacesToDrop += [newName, name]
        defer { try? fm.removeItem(atPath: tsDir) }

        do {
            // Create
            try await client.admin.createTablespace(name: name, location: tsDir)
        } catch {
            // If creation fails (e.g. Docker, permissions), skip the test
            throw XCTSkip("Could not create tablespace (likely a permissions or Docker issue): \(error)")
        }

        // Verify creation
        var tablespaces: [PostgresTablespaceInfo] = try await client.metadata.listTablespaces()
        XCTAssertTrue(tablespaces.contains(where: { $0.name == name }), "Tablespace '\(name)' should exist")

        // Rename
        try await client.admin.alterTablespaceRename(name: name, newName: newName)
        tablespaces = try await client.metadata.listTablespaces()
        XCTAssertTrue(tablespaces.contains(where: { $0.name == newName }), "Tablespace should be renamed to '\(newName)'")
        XCTAssertFalse(tablespaces.contains(where: { $0.name == name }), "Old tablespace name '\(name)' should not exist")

        // Change owner
        try await client.admin.alterTablespaceOwner(name: newName, newOwner: "postgres")
        tablespaces = try await client.metadata.listTablespaces()
        let ts = tablespaces.first(where: { $0.name == newName })
        XCTAssertEqual(ts?.owner, "postgres", "Tablespace owner should be 'postgres'")
    }

    // MARK: - Event Trigger: Rename, Owner, Enable, Disable

    func testEventTriggerRenameOwnerEnableDisable() async throws {
        let funcName = uniqueName("evtfn")
        let name = uniqueName("evt")
        let newName = uniqueName("evt_ren")
        defer { Task { [client = self.client!] in
            _ = try? await client.triggers.dropEventTrigger(name: newName, ifExists: true, cascade: true)
            _ = try? await client.triggers.dropEventTrigger(name: name, ifExists: true, cascade: true)
            _ = try? await client.simpleQuery("DROP FUNCTION IF EXISTS \(funcName)() CASCADE")
        }}

        // Create an event trigger function
        _ = try await client.simpleQuery("""
            CREATE OR REPLACE FUNCTION \(funcName)() RETURNS event_trigger
            LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE 'event trigger fired'; END; $$
            """)

        // Create event trigger
        try await client.triggers.createEventTrigger(name: name, event: "ddl_command_end", function: funcName)

        // Verify creation
        var triggers = try await client.metadata.listEventTriggers()
        XCTAssertTrue(triggers.contains(where: { $0.name == name }), "Event trigger '\(name)' should exist")

        // Rename
        try await client.triggers.alterEventTriggerRename(name: name, newName: newName)
        triggers = try await client.metadata.listEventTriggers()
        XCTAssertTrue(triggers.contains(where: { $0.name == newName }), "Event trigger should be renamed to '\(newName)'")
        XCTAssertFalse(triggers.contains(where: { $0.name == name }), "Old event trigger name '\(name)' should not exist")

        // Change owner
        try await client.triggers.alterEventTriggerOwner(name: newName, newOwner: "postgres")
        triggers = try await client.metadata.listEventTriggers()
        let trigger = triggers.first(where: { $0.name == newName })
        XCTAssertEqual(trigger?.owner, "postgres", "Event trigger owner should be 'postgres'")

        // Disable
        try await client.triggers.alterEventTriggerEnable(name: newName, enable: false)
        triggers = try await client.metadata.listEventTriggers()
        let disabledTrigger = triggers.first(where: { $0.name == newName })
        XCTAssertEqual(disabledTrigger?.enabled, "D", "Event trigger should be disabled (enabled = 'D')")

        // Enable
        try await client.triggers.alterEventTriggerEnable(name: newName, enable: true)
        triggers = try await client.metadata.listEventTriggers()
        let enabledTrigger = triggers.first(where: { $0.name == newName })
        XCTAssertEqual(enabledTrigger?.enabled, "O", "Event trigger should be enabled (enabled = 'O')")
    }

    // MARK: - Aggregate: Rename, Owner, Schema

    func testAggregateRenameOwnerSchema() async throws {
        let name = uniqueName("agg")
        let newName = uniqueName("agg_ren")
        defer { Task { [client = self.client!] in
            _ = try? await client.admin.dropAggregate(name: newName, inputType: "integer", ifExists: true, cascade: true, schema: "app")
            _ = try? await client.admin.dropAggregate(name: newName, inputType: "integer", ifExists: true, cascade: true, schema: "public")
            _ = try? await client.admin.dropAggregate(name: name, inputType: "integer", ifExists: true, cascade: true, schema: "public")
        }}

        // Create a simple sum-like aggregate
        try await client.admin.createAggregate(
            name: name,
            inputType: "integer",
            sfunc: "int4pl",
            stype: "integer",
            initcond: "0",
            schema: "public"
        )

        // Verify creation
        var aggregates = try await client.metadata.listAggregates(schema: "public")
        XCTAssertTrue(aggregates.contains(where: { $0.name == name }), "Aggregate '\(name)' should exist")

        // Rename
        try await client.admin.alterAggregateRename(name: name, inputType: "integer", newName: newName, schema: "public")
        aggregates = try await client.metadata.listAggregates(schema: "public")
        XCTAssertTrue(aggregates.contains(where: { $0.name == newName }), "Aggregate should be renamed to '\(newName)'")
        XCTAssertFalse(aggregates.contains(where: { $0.name == name }), "Old aggregate name '\(name)' should not exist")

        // Change owner
        try await client.admin.alterAggregateOwner(name: newName, inputType: "integer", newOwner: "postgres", schema: "public")

        // Change schema
        try await client.admin.alterAggregateSetSchema(name: newName, inputType: "integer", newSchema: "app", schema: "public")
        let publicAggs = try await client.metadata.listAggregates(schema: "public")
        XCTAssertFalse(publicAggs.contains(where: { $0.name == newName }), "Aggregate should no longer be in 'public'")
        let appAggs = try await client.metadata.listAggregates(schema: "app")
        XCTAssertTrue(appAggs.contains(where: { $0.name == newName }), "Aggregate should now be in 'app'")
    }

    // MARK: - Language: Rename, Owner

    func testLanguageRenameOwner() async throws {
        // Creating a truly new language requires C handler functions, which is complex.
        // Instead, we test rename and owner on an existing PL language by creating a
        // temporary one if possible, or skip.
        let name = uniqueName("lang")
        let newName = uniqueName("lang_ren")
        defer { Task { [client = self.client!] in
            _ = try? await client.admin.dropLanguage(name: newName, ifExists: true, cascade: true)
            _ = try? await client.admin.dropLanguage(name: name, ifExists: true, cascade: true)
        }}

        // Create a trusted PL language using the plpgsql handler (a common workaround for testing).
        // This requires plpgsql to already exist (which it does by default in most PG installations).
        do {
            _ = try await client.simpleQuery("""
                CREATE TRUSTED LANGUAGE \(name)
                HANDLER plpgsql_call_handler
                VALIDATOR plpgsql_validator
                """)
        } catch {
            throw XCTSkip("Could not create test language (plpgsql handler may not be available): \(error)")
        }

        // Verify creation
        var languages = try await client.metadata.listLanguages()
        XCTAssertTrue(languages.contains(where: { $0.name == name }), "Language '\(name)' should exist")

        // Rename
        try await client.admin.alterLanguageRename(name: name, newName: newName)
        languages = try await client.metadata.listLanguages()
        XCTAssertTrue(languages.contains(where: { $0.name == newName }), "Language should be renamed to '\(newName)'")
        XCTAssertFalse(languages.contains(where: { $0.name == name }), "Old language name '\(name)' should not exist")

        // Change owner
        try await client.admin.alterLanguageOwner(name: newName, newOwner: "postgres")
        languages = try await client.metadata.listLanguages()
        let lang = languages.first(where: { $0.name == newName })
        XCTAssertEqual(lang?.owner, "postgres", "Language owner should be 'postgres'")
    }

    // MARK: - FTS Configuration: Rename, Owner, Schema

    func testFTSConfigRenameOwnerSchema() async throws {
        let name = uniqueName("fts")
        let newName = uniqueName("fts_ren")
        defer { Task { [client = self.client!] in
            _ = try? await client.admin.dropTextSearchConfiguration(name: newName, ifExists: true, cascade: true, schema: "app")
            _ = try? await client.admin.dropTextSearchConfiguration(name: newName, ifExists: true, cascade: true, schema: "public")
            _ = try? await client.admin.dropTextSearchConfiguration(name: name, ifExists: true, cascade: true, schema: "public")
        }}

        // Create by copying the built-in 'english' configuration
        try await client.admin.createTextSearchConfiguration(name: name, copy: "english", schema: "public")

        // Verify creation
        var configs = try await client.metadata.listTextSearchConfigurations(schema: "public")
        XCTAssertTrue(configs.contains(where: { $0.name == name }), "FTS config '\(name)' should exist")

        // Rename
        try await client.admin.alterTextSearchConfigurationRename(name: name, newName: newName, schema: "public")
        configs = try await client.metadata.listTextSearchConfigurations(schema: "public")
        XCTAssertTrue(configs.contains(where: { $0.name == newName }), "FTS config should be renamed to '\(newName)'")
        XCTAssertFalse(configs.contains(where: { $0.name == name }), "Old FTS config name '\(name)' should not exist")

        // Change owner
        try await client.admin.alterTextSearchConfigurationOwner(name: newName, newOwner: "postgres", schema: "public")

        // Change schema
        try await client.admin.alterTextSearchConfigurationSetSchema(name: newName, newSchema: "app", schema: "public")
        let publicConfigs = try await client.metadata.listTextSearchConfigurations(schema: "public")
        XCTAssertFalse(publicConfigs.contains(where: { $0.name == newName }), "FTS config should no longer be in 'public'")
        let appConfigs = try await client.metadata.listTextSearchConfigurations(schema: "app")
        XCTAssertTrue(appConfigs.contains(where: { $0.name == newName }), "FTS config should now be in 'app'")
    }

    // MARK: - Rule: Rename

    func testRuleRename() async throws {
        let table = uniqueName("rule_tbl")
        let ruleName = uniqueName("rule")
        let newRuleName = uniqueName("rule_ren")
        defer { Task { [client = self.client!] in
            _ = try? await client.admin.dropRule(name: newRuleName, table: table, ifExists: true, cascade: true, schema: "public")
            _ = try? await client.admin.dropRule(name: ruleName, table: table, ifExists: true, cascade: true, schema: "public")
            _ = try? await client.admin.dropTable(name: table, ifExists: true)
        }}

        // Create table
        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            .text(name: "name")
        ])

        // Create a DO INSTEAD NOTHING rule on INSERT
        try await client.admin.createRule(
            name: ruleName,
            table: table,
            event: "INSERT",
            doInstead: true,
            commands: "NOTHING",
            schema: "public"
        )

        // Verify creation
        var rules = try await client.metadata.listRules(schema: "public", table: table)
        XCTAssertTrue(rules.contains(where: { $0.name == ruleName }), "Rule '\(ruleName)' should exist on '\(table)'")

        // Rename
        try await client.admin.alterRuleRename(ruleName: ruleName, tableName: table, newName: newRuleName, schema: "public")
        rules = try await client.metadata.listRules(schema: "public", table: table)
        XCTAssertTrue(rules.contains(where: { $0.name == newRuleName }), "Rule should be renamed to '\(newRuleName)'")
        XCTAssertFalse(rules.contains(where: { $0.name == ruleName }), "Old rule name '\(ruleName)' should not exist")
    }
}
