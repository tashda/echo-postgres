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

    @Test func procedureSQL() {
        let sql = PostgresRoutineClient.procedureSQL(
            name: "\"s\".\"p\"", parameters: ["IN \"x\" integer"], body: "'SELECT 1'",
            language: .sql, orReplace: true, security: .invoker
        )
        #expect(sql == "CREATE OR REPLACE PROCEDURE \"s\".\"p\"(IN \"x\" integer) LANGUAGE SQL SECURITY INVOKER AS 'SELECT 1'")
    }
}
