import Foundation
import Logging
@testable import PostgresKit
import Testing

/// Objects created in a named schema, procedures, exact row counts and insert counts.
@Suite(.enabled(if: TestEnv.isConfigured))
struct SchemaQualifiedObjectsTests {
    private func connect() async throws -> PostgresClient {
        try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port, database: TestEnv.database,
            username: TestEnv.username, password: TestEnv.password, useTLS: TestEnv.useTLS
        ))
    }

    @Test func createsEveryObjectInANamedSchema() async throws {
        do {
            try await createEveryObject()
        } catch {
            Issue.record("\(String(reflecting: error))")
        }
    }

    private func createEveryObject() async throws {
        let client = try await connect()
        defer { client.close() }
        let schema = "sq_" + UUID().uuidString.prefix(8).lowercased()
        _ = try await client.admin.createSchema(name: schema)
        defer { Task { _ = try? await client.admin.dropSchema(name: schema, ifExists: true, cascade: true) } }

        _ = try await client.admin.createTable(name: "orders", schema: schema, columns: [
            PostgresColumnDefinition(name: "id", dataType: "integer", nullable: false, primaryKey: true),
            PostgresColumnDefinition(name: "status", dataType: "text"),
        ])
        let inserted = try await client.bulk.insert(into: "orders", schema: schema, columns: ["id", "status"], values: [
            [PostgresInsertValue(1), PostgresInsertValue("new")],
            [PostgresInsertValue(2), PostgresInsertValue("paid")],
            [PostgresInsertValue(3), PostgresInsertValue("paid")],
        ])
        #expect(inserted == 3)
        #expect(try await client.metadata.exactRowCount(schema: schema, table: "orders") == 3)

        _ = try await client.views.createView(name: "paid", schema: schema, query: "SELECT id FROM \"\(schema)\".orders WHERE status = 'paid'")
        _ = try await client.views.createMaterializedView(name: "paid_mv", schema: schema, query: "SELECT id FROM \"\(schema)\".orders")
        _ = try await client.sequences.createSequence(name: "numbers", schema: schema, startWith: 100)
        _ = try await client.types.createEnum(name: "state", schema: schema, values: ["new", "paid"])
        #expect(try await client.types.createEnum(name: "state", schema: schema, values: ["new"], ifNotExists: true) == 0)
        #expect(try await client.types.typeExists(name: "state", schema: schema))
        _ = try await client.routines.createFunction(
            name: "touch", schema: schema, parameters: [], returnType: "trigger",
            body: "BEGIN RETURN NEW; END", language: .plpgsql, security: .invoker
        )
        _ = try await client.triggers.createTrigger(
            name: "orders_touch", table: "orders", schema: schema, event: .before, operations: [.update],
            procedure: "\"\(schema)\".touch()"
        )
        _ = try await client.routines.createProcedure(
            name: "mark_paid", schema: schema,
            parameters: [PostgresFunctionParameter(name: "order_id", dataType: "integer")],
            body: "BEGIN UPDATE \"\(schema)\".orders SET status = 'paid' WHERE id = order_id; END"
        )
        let objects = try await client.metadata.listTablesAndViews(schema: schema).map(\.name)
        #expect(objects.contains("orders"))
        #expect(objects.contains("paid"))
    }

    @Test func indexesAndConstraintsInANamedSchema() async throws {
        do {
            try await createIndexesAndConstraints()
        } catch {
            Issue.record("\(String(reflecting: error))")
        }
    }

    private func createIndexesAndConstraints() async throws {
        let client = try await connect()
        defer { client.close() }
        let schema = "ix_" + UUID().uuidString.prefix(8).lowercased()
        _ = try await client.admin.createSchema(name: schema)
        defer { Task { _ = try? await client.admin.dropSchema(name: schema, ifExists: true, cascade: true) } }

        _ = try await client.admin.createTable(name: "parents", schema: schema, columns: [
            PostgresColumnDefinition(name: "id", dataType: "integer", nullable: false),
        ])
        _ = try await client.admin.createTable(name: "items", schema: schema, columns: [
            PostgresColumnDefinition(name: "id", dataType: "integer", nullable: false),
            PostgresColumnDefinition(name: "parent_id", dataType: "integer"),
            PostgresColumnDefinition(name: "email", dataType: "text"),
            PostgresColumnDefinition(name: "doc", dataType: "jsonb"),
            PostgresColumnDefinition(name: "spot", dataType: "point"),
            PostgresColumnDefinition(name: "price", dataType: "numeric"),
        ])
        _ = try await client.constraints.addPrimaryKey(table: "parents", schema: schema, column: "id")
        _ = try await client.constraints.addPrimaryKey(table: "items", schema: schema, column: "id")
        _ = try await client.constraints.addForeignKey(
            table: "items", schema: schema, column: "parent_id", referencesTable: "parents", referencesColumn: "id", onDelete: .cascade
        )
        _ = try await client.constraints.addUniqueConstraint(table: "items", schema: schema, columns: ["email"])
        _ = try await client.constraints.addCheckConstraint(table: "items", schema: schema, condition: "price >= 0", constraintName: "price_positive")

        _ = try await client.indexes.createIndex(name: "items_parent", table: "items", schema: schema, columns: ["parent_id"])
        _ = try await client.indexes.createAdvancedIndex(
            name: "items_doc", table: "items", schema: schema,
            columns: [PostgresIndexColumn(name: "doc", operatorClass: "jsonb_path_ops")], indexType: .gin
        )
        _ = try await client.indexes.createAdvancedIndex(
            name: "items_email_lower", table: "items", schema: schema,
            columns: [PostgresIndexColumn(expression: "lower(email)")], unique: true, include: ["price"], whereClause: "email IS NOT NULL"
        )
        _ = try await client.indexes.createAdvancedIndex(
            name: "items_spot", table: "items", schema: schema, columns: [PostgresIndexColumn(name: "spot")], indexType: .spgist
        )
        let indexes = try await client.metadata.listIndexes(schema: schema, table: "items").map(\.name)
        for name in ["items_parent", "items_doc", "items_email_lower", "items_spot"] {
            #expect(indexes.contains(name), "\(name)")
        }
    }

    @Test func grantsAndPoliciesInANamedSchema() async throws {
        do {
            try await createGrantsAndPolicies()
        } catch {
            Issue.record("\(String(reflecting: error))")
        }
    }

    private func createGrantsAndPolicies() async throws {
        let client = try await connect()
        defer { client.close() }
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let schema = "sec_\(suffix)", reader = "reader_\(suffix)", group = "group_\(suffix)"
        _ = try await client.admin.createSchema(name: schema)
        _ = try await client.security.createRole(name: group)
        _ = try await client.security.createRole(name: reader, login: true)
        defer {
            Task {
                _ = try? await client.admin.dropSchema(name: schema, ifExists: true, cascade: true)
                try? await client.security.dropOwned(by: reader)
                _ = try? await client.security.dropRole(name: reader, ifExists: true)
                _ = try? await client.security.dropRole(name: group, ifExists: true)
            }
        }
        _ = try await client.admin.createTable(name: "salaries", schema: schema, columns: [
            PostgresColumnDefinition(name: "employee", dataType: "text"),
            PostgresColumnDefinition(name: "salary", dataType: "numeric"),
            PostgresColumnDefinition(name: "region", dataType: "text"),
        ])
        _ = try await client.security.grantRole(role: group, to: reader, inherit: true)
        _ = try await client.security.grantPrivileges(privileges: [.select], onTable: "salaries", schema: schema, columns: ["employee", "region"], to: reader)
        _ = try await client.security.grantPrivileges(privileges: [.select], onTable: "salaries", schema: schema, to: "PUBLIC")
        _ = try await client.security.revokePrivileges(privileges: [.select], onTable: "salaries", schema: schema, from: "PUBLIC")
        _ = try await client.admin.alterTableRowLevelSecurity(table: "salaries", enable: true, schema: schema)
        _ = try await client.security.createPolicy(name: "own_region", table: "salaries", schema: schema, command: .select,
                                                   to: [group, "CURRENT_USER"], using: "region = current_user")
        let policies = try await client.metadata.listPolicies(schema: schema, table: "salaries")
        #expect(policies.count == 1)
    }

    @Test func procedureSQL() {
        let sql = PostgresRoutineClient.procedureSQL(
            name: "\"s\".\"p\"", parameters: ["IN \"x\" integer"], body: "'SELECT 1'",
            language: .sql, orReplace: true, security: .invoker
        )
        #expect(sql == "CREATE OR REPLACE PROCEDURE \"s\".\"p\"(IN \"x\" integer) LANGUAGE SQL SECURITY INVOKER AS 'SELECT 1'")
    }
}
