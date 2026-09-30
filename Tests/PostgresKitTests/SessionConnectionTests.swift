import Foundation
import Logging
import XCTest
@testable import PostgresKit

/// ``PostgresSessionConnection``: one pinned connection with transaction tracking, loss detection,
/// server-side cancel and script execution.
final class SessionConnectionTests: PostgresKitTestCase {
    private var session: PostgresSessionConnection!
    private var admin: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        session = try await PostgresSessionConnection.connect(configuration: TestEnv.configuration(applicationName: "SessionTests"), logger: logger)
        admin = try await PostgresKit.PostgresClient.connect(configuration: TestEnv.configuration(applicationName: "SessionTestsAdmin"), logger: logger)
    }

    override func tearDown() async throws {
        await session?.close()
        admin?.close()
        try await super.tearDown()
    }

    private func scalar(_ sql: String) async throws -> String? {
        let result = try await session.queryResult(sql)
        return result.rows.first.flatMap { row in row.first.flatMap { PostgresCellFormatter().stringValue(for: $0) } }
    }

    private func uniqueTable() -> String { "session_\(UInt32.random(in: 0..<UInt32.max))" }

    // MARK: - Transactions

    func testTransactionOutlivesThePoolIdleTimeout() async throws {
        // Measured before this change: BEGIN → INSERT → idle 65 s → COMMIT on the pooled client lost the row.
        let table = uniqueTable()
        _ = try await session.queryResult("CREATE TABLE \(table) (id int)")
        defer { Task { [admin = admin!] in _ = try? await admin.simpleQuery("DROP TABLE IF EXISTS \(table)") } }

        _ = try await session.queryResult("BEGIN")
        XCTAssertEqual(session.transactionStatus, .inTransaction)
        _ = try await session.queryResult("INSERT INTO \(table) VALUES (1)")
        let pidBefore = try await scalar("SELECT pg_backend_pid()")
        try await Task.sleep(for: .seconds(3))
        let pidAfter = try await scalar("SELECT pg_backend_pid()")
        _ = try await session.queryResult("COMMIT")
        XCTAssertEqual(session.transactionStatus, .idle)
        XCTAssertEqual(pidBefore, pidAfter, "every statement runs on the same backend")
        XCTAssertEqual(pidBefore, String(session.backendPID))

        let committed = try await admin.simpleQueryResult("SELECT count(*) FROM \(table)")
        XCTAssertEqual(try committed.rows.first?.decode(Int.self), 1)
    }

    func testFailedTransactionIsTrackedAndRecovered() async throws {
        _ = try await session.queryResult("BEGIN")
        do {
            for try await _ in try await session.query("SELECT 1 / 0") {}
            XCTFail("division by zero should fail")
        } catch let error as PostgresError {
            XCTAssertEqual(error.sqlState, "22012")
        }
        XCTAssertEqual(session.transactionStatus, .failed)
        let refreshed = try await session.refreshTransactionStatus()
        XCTAssertEqual(refreshed, .failed)
        _ = try await session.queryResult("ROLLBACK")
        XCTAssertEqual(session.transactionStatus, .idle)
        let value1 = try await session.refreshTransactionStatus()
        XCTAssertEqual(value1, .idle)
    }

    func testRefreshDetectsTransactionsStartedInsideStatements() async throws {
        let value2 = try await session.refreshTransactionStatus()
        XCTAssertEqual(value2, .idle)
        _ = try await session.queryResult("START TRANSACTION READ ONLY")
        let value3 = try await session.refreshTransactionStatus()
        XCTAssertEqual(value3, .inTransaction)
        _ = try await session.queryResult("SAVEPOINT s1")
        _ = try? await session.queryResult("SELECT missing_column FROM pg_class")
        XCTAssertEqual(session.transactionStatus, .failed)
        _ = try await session.queryResult("ROLLBACK TO SAVEPOINT s1")
        XCTAssertEqual(session.transactionStatus, .inTransaction)
        _ = try await session.queryResult("COMMIT")
        XCTAssertEqual(session.transactionStatus, .idle)
    }

    func testSessionStateIsKept() async throws {
        _ = try await session.queryResult("SET search_path TO pg_catalog")
        _ = try await session.queryResult("CREATE TEMP TABLE session_temp AS SELECT 7 AS v")
        let value4 = try await scalar("SHOW search_path")
        XCTAssertEqual(value4, "pg_catalog")
        let value5 = try await scalar("SELECT v FROM session_temp")
        XCTAssertEqual(value5, "7")
        let value6 = try await scalar("SHOW application_name")
        XCTAssertEqual(value6, "SessionTests")
    }

    // MARK: - Loss detection

    func testLostConnectionReportsLostTransaction() async throws {
        _ = try await session.queryResult("BEGIN")
        _ = try await admin.cancelBackend(pid: 0) // warms up the pool
        _ = try await admin.simpleQueryResult("SELECT pg_terminate_backend(\(session.backendPID))")
        for _ in 0..<50 where !session.isClosed { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(session.isClosed)
        do {
            _ = try await session.queryResult("COMMIT")
            XCTFail("COMMIT on a dead session must fail, not silently reconnect")
        } catch let error as PostgresSessionError {
            XCTAssertEqual(error, .connectionClosed(transactionLost: true))
        }
    }

    // MARK: - Cancel and timeouts

    func testCancelStopsTheServerQuery() async throws {
        let started = Date()
        let session = self.session!
        let running = Task { () -> String? in
            do {
                for try await _ in try await session.query("SELECT pg_sleep(10)") {}
                return nil
            } catch let error as PostgresError {
                return error.sqlState
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(session.isQueryInFlight)
        let signalled = try await session.cancel()
        XCTAssertTrue(signalled)
        let sqlState = try await running.value
        XCTAssertEqual(sqlState, "57014")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "measured 6 s before, for a 0.5 s cancel")
        let value7 = try await scalar("SELECT 1")
        XCTAssertEqual(value7, "1", "the session is usable after a cancel")
    }

    func testCancelThroughAPool() async throws {
        let session = self.session!
        let running = Task { () -> String? in
            do {
                for try await _ in try await session.query("SELECT pg_sleep(10)") {}
                return nil
            } catch let error as PostgresError {
                return error.sqlState
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        let value8 = try await session.cancel(using: admin)
        XCTAssertTrue(value8)
        let sqlState = try await running.value
        XCTAssertEqual(sqlState, "57014")
    }

    func testStatementTimeouts() async throws {
        let timed = try await PostgresSessionConnection.connect(configuration: TestEnv.configuration(statementTimeout: .milliseconds(300)), logger: logger)
        defer { Task { await timed.close() } }
        do {
            _ = try await timed.queryResult("SELECT pg_sleep(2)")
            XCTFail("statement_timeout should cancel the statement")
        } catch let error as PostgresError {
            XCTAssertEqual(error.sqlState, "57014")
        }
        try await timed.setStatementTimeout(.zero)
        _ = try await timed.queryResult("SELECT pg_sleep(0.5)")
        try await timed.setStatementTimeout(nil)
        let restored = try await timed.queryResult("SHOW statement_timeout")
        XCTAssertEqual(try restored.rows.first?.decode(String.self), "300ms", "nil restores the configured default")
        try await session.setStatementTimeout(.milliseconds(1500))
        let value = try await scalar("SHOW statement_timeout")
        XCTAssertEqual(value, "1500ms")
    }

    // MARK: - Scripts and streaming

    func testExecuteScriptRunsEveryStatement() async throws {
        let table = uniqueTable()
        defer { Task { [admin = admin!] in _ = try? await admin.simpleQuery("DROP TABLE IF EXISTS \(table)") } }
        let script = """
        CREATE TABLE \(table) (id int, note text);
        INSERT INTO \(table) VALUES (1, 'a;b'), (2, $$semi;colon$$);
        -- a comment between statements
        UPDATE \(table) SET note = note || '!' WHERE id = 2;
        SELECT id, note FROM \(table) ORDER BY id;
        """
        var tags: [String] = []
        var rows: [[String?]] = []
        try await session.executeScript(script) { _, outcome in
            switch outcome {
            case .command(let result):
                tags.append(result.metadata.command)
            case .rows(let sequence):
                for try await row in sequence { rows.append(row.map(PostgresCellFormatter().stringValue(for:))) }
            }
        }
        XCTAssertEqual(tags, ["CREATE TABLE", "INSERT", "UPDATE"])
        XCTAssertEqual(rows, [["1", "a;b"], ["2", "semi;colon!"]])
    }

    func testExecuteScriptNamesTheFailingStatement() async throws {
        do {
            try await session.executeScript("SELECT 1; SELECT * FROM no_such_table_xyz; SELECT 3") { _, outcome in
                if case .rows(let rows) = outcome { _ = try await rows.collect() }
            }
            XCTFail("expected a script error")
        } catch let error as PostgresScriptError {
            XCTAssertEqual(error.statement.index, 1)
            XCTAssertEqual((error.underlying as? PostgresError)?.sqlState, "42P01")
            XCTAssertEqual((error.underlying as? PostgresError)?.position, 15)
        }
    }

    func testStreamsEveryRowPastThePreview() async throws {
        var count = 0
        var last: String?
        let formatter = PostgresCellFormatter()
        for try await row in try await session.query("SELECT g FROM generate_series(1, 25000) g") {
            count += 1
            last = row.first.flatMap(formatter.stringValue(for:))
        }
        XCTAssertEqual(count, 25_000)
        XCTAssertEqual(last, "25000")
        XCTAssertFalse(session.isQueryInFlight)
    }
}
