import Foundation
@testable import PostgresKit
import Testing

@Suite struct ScriptStepTests {
    @Test func splitsStatementsAndKeepsLines() {
        let steps = PostgresScript.steps(in: "CREATE TABLE t (a int);\n\nINSERT INTO t VALUES (1);\nSELECT 1")
        #expect(steps == [.statement("CREATE TABLE t (a int)", line: 1), .statement("INSERT INTO t VALUES (1)", line: 3), .statement("SELECT 1", line: 4)])
    }

    @Test func semicolonsInsideQuotesCommentsAndDollarBodiesDoNotSplit() {
        let script = """
        -- leading comment; with a semicolon
        SELECT 'a;b', "odd;name", E'it\\'s;';
        /* block; /* nested; */ still; */ SELECT 2;
        CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $body$ BEGIN RETURN 1; END; $body$;
        CREATE FUNCTION g() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql;
        SELECT $1::int;
        """
        let steps = PostgresScript.steps(in: script)
        #expect(steps.count == 5)
        if case .statement(let sql, _) = steps[2] { #expect(sql.hasSuffix("END; $body$")) }
        if case .statement(let sql, _) = steps[4] { #expect(sql == "SELECT $1::int") }
    }

    @Test func copyFromStdinCarriesItsData() {
        let script = "COPY public.t (a, b) FROM stdin;\n1\tone\n2\t\\N\n\\.\nSELECT 3;\n"
        #expect(PostgresScript.steps(in: script) == [
            .copy(statement: "COPY public.t (a, b) FROM stdin", data: "1\tone\n2\t\\N\n", line: 1),
            .statement("SELECT 3", line: 5),
        ])
    }

    @Test func metaCommandsAreSeparateSteps() {
        let steps = PostgresScript.steps(in: "\\restrict abc\nSET x = 1;\n\\connect other\n")
        #expect(steps == [.metaCommand("\\restrict abc", line: 1), .statement("SET x = 1", line: 2), .metaCommand("\\connect other", line: 3)])
    }
}

@Suite(.enabled(if: TestEnv.isConfigured))
struct ScriptRunTests {
    @Test func runsADumpShapedScript() async throws {
        let client = try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port, database: TestEnv.database,
            username: TestEnv.username, password: TestEnv.password, useTLS: TestEnv.useTLS
        ))
        defer { client.close() }
        let schema = "dump_" + UUID().uuidString.prefix(8).lowercased()
        defer { Task { _ = try? await client.admin.dropSchema(name: schema, ifExists: true, cascade: true) } }
        let summary = try await client.scripts.run("""
        \\restrict lab
        SET check_function_bodies = false;
        SELECT pg_catalog.set_config('search_path', '', false);
        CREATE SCHEMA \(schema);
        -- References a table that does not exist yet: needs check_function_bodies = false.
        CREATE FUNCTION \(schema).total() RETURNS bigint LANGUAGE sql AS $$ SELECT sum(n) FROM \(schema).numbers; $$;
        CREATE TABLE \(schema).numbers (n integer, label text);
        COPY \(schema).numbers (n, label) FROM stdin;
        1\tone
        2\ttwo; with a semicolon
        3\t\\N
        \\.
        \\unrestrict lab
        """)
        #expect(summary.statementsRun == 5)
        #expect(summary.copiesRun == 1)
        #expect(summary.skippedMetaCommands == ["\\restrict lab", "\\unrestrict lab"])
        #expect(try await client.metadata.exactRowCount(schema: schema, table: "numbers") == 3)
    }
}
