import Foundation
import PGLibpq
import Testing

@Suite("PGConnection on a lab server", .labServer, .serialized)
struct PGConnectionTests {
    @Test func connectsAndReportsTheServer() async throws {
        let connection = try await LabServer.connect()
        #expect(await connection.isOpen)
        #expect(await connection.serverVersion >= 140_000)
        #expect(await connection.backendPID > 0)
        #expect(await connection.transactionStatus == .idle)
        #expect(await connection.parameterStatus("server_encoding") == "UTF8")
        let results = try await connection.execute("SELECT application_name FROM pg_stat_activity WHERE pid = pg_backend_pid()")
        #expect(results.first?.string(row: 0, column: 0) == "PGLibpqTests")
        await connection.close()
        #expect(await !connection.isOpen)
    }

    @Test func rowsArriveInChunks() async throws {
        let connection = try await LabServer.connect()
        defer { Task { await connection.close() } }
        try await connection.send("SELECT g, md5(g::text) FROM generate_series(1, 100000) g", chunkSize: 512)
        var rows = 0, chunks = 0, last: Int?
        var statuses: [PGResult.Status] = []
        while let result = try await connection.nextResult() {
            statuses.append(result.status)
            #expect(result.columnCount == 2)
            #expect(result.columnName(0) == "g")
            #expect(result.columnType(0) == 23)
            rows += result.rowCount
            if result.rowCount > 0 { chunks += 1; last = result.string(row: result.rowCount - 1, column: 0).flatMap { Int($0) } }
        }
        #expect(rows == 100_000)
        #expect(chunks >= 100_000 / 512)
        #expect(last == 100_000)
        #expect(statuses.last == .rowsDone)
        #expect(await !connection.isBusy)
    }

    @Test func severalStatementsGiveSeveralResults() async throws {
        let connection = try await LabServer.connect()
        defer { Task { await connection.close() } }
        let results = try await connection.execute("""
            SELECT 1; CREATE TEMP TABLE t (i int); INSERT INTO t VALUES (1), (2); SELECT 'a' AS x, NULL AS y
            """)
        #expect(results.map(\.status) == [.rowsDone, .commandDone, .commandDone, .rowsDone])
        #expect(results[1].commandStatus == "CREATE TABLE")
        #expect(results[2].affectedRows == 2)
        #expect(results[3].string(row: 0, column: 0) == "a")
        #expect(results[3].string(row: 0, column: 1) == nil)
    }

    @Test func errorsCarryTheServerFields() async throws {
        let connection = try await LabServer.connect()
        defer { Task { await connection.close() } }
        let results = try await connection.execute("""
            CREATE TEMP TABLE u (id int PRIMARY KEY); INSERT INTO u VALUES (1); INSERT INTO u VALUES (1); SELECT 2
            """)
        // The failing statement ends the batch: no result for SELECT 2.
        #expect(results.map(\.status) == [.commandDone, .commandDone, .error])
        let error = try #require(results.last?.error)
        #expect(error.sqlState == "23505")
        #expect(error.severity == "ERROR")
        #expect(error.table == "u")
        #expect(error.constraint == "u_pkey")
        #expect(error.detail?.contains("(id)=(1)") == true)
        #expect(try await connection.execute("SELECT 1").first?.string(row: 0, column: 0) == "1")
    }

    @Test func noticesAreKept() async throws {
        let connection = try await LabServer.connect()
        defer { Task { await connection.close() } }
        _ = try await connection.execute("DO $$ BEGIN RAISE NOTICE 'hello %', 42; RAISE WARNING 'careful'; END $$")
        let notices = await connection.takeNotices()
        #expect(notices.map(\.message) == ["hello 42", "careful"])
        #expect(notices.map(\.severity) == ["NOTICE", "WARNING"])
        #expect(await connection.takeNotices().isEmpty)
    }

    @Test func cancelStopsARunningStatement() async throws {
        let connection = try await LabServer.connect()
        defer { Task { await connection.close() } }
        let started = ContinuousClock.now
        try await connection.send("SELECT pg_sleep(30)")
        async let cancelled: Void = {
            try await Task.sleep(for: .milliseconds(500))
            try await connection.cancel()
        }()
        var error: PGServerError?
        while let result = try await connection.nextResult() {
            if result.status == .error { error = result.error }
        }
        try await cancelled
        #expect(error?.sqlState == "57014")
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(try await connection.execute("SELECT 1").first?.string(row: 0, column: 0) == "1")
    }

    @Test func transactionStatusFollowsTheSession() async throws {
        let connection = try await LabServer.connect()
        defer { Task { await connection.close() } }
        _ = try await connection.execute("BEGIN")
        #expect(await connection.transactionStatus == .inTransaction)
        _ = try await connection.execute("SELECT 1/0")
        #expect(await connection.transactionStatus == .failedTransaction)
        _ = try await connection.execute("ROLLBACK")
        #expect(await connection.transactionStatus == .idle)
    }

    @Test func busyConnectionRefusesASecondStatement() async throws {
        let connection = try await LabServer.connect()
        defer { Task { await connection.close() } }
        try await connection.send("SELECT pg_sleep(0.2)")
        await #expect(throws: PGConnectionError.self) { try await connection.send("SELECT 1") }
        while try await connection.nextResult() != nil {}
        #expect(try await connection.execute("SELECT 1").count == 1)
    }

    @Test func wrongPasswordFailsWithLibpqsMessage() async throws {
        var parameters = LabServer.parameters
        parameters.set("password", "definitely-wrong")
        do {
            _ = try await PGConnection.connect(parameters, timeout: .seconds(15))
            Issue.record("signed in with a wrong password")
        } catch let error as PGConnectionError {
            #expect(error.kind == .connectFailed)
            #expect(error.message.contains("password authentication failed"))
        }
    }

    @Test func taskCancellationWhileWaitingThrows() async throws {
        let connection = try await LabServer.connect()
        defer { Task { await connection.close() } }
        try await connection.send("SELECT pg_sleep(10)")
        let reader = Task { try await connection.nextResult() }
        try await Task.sleep(for: .milliseconds(300))
        reader.cancel()
        await #expect(throws: CancellationError.self) { try await reader.value }
        // The statement is still running: cancel it and drain before reuse.
        try await connection.cancel()
        while try await connection.nextResult() != nil {}
        #expect(try await connection.execute("SELECT 1").count == 1)
    }
}

@Suite("PGConnection without a server")
struct PGConnectionOfflineTests {
    @Test func connectDeadlineAppliesToTheWholeAttempt() async throws {
        // A non-routable address: the TCP connect never completes.
        let parameters = PGConnectionParameters(["host": "10.255.255.1", "port": "5432", "user": "x", "dbname": "x", "gssencmode": "disable", "sslmode": "disable"])
        let started = ContinuousClock.now
        do {
            _ = try await PGConnection.connect(parameters, timeout: .seconds(1))
            Issue.record("connected to a black hole")
        } catch let error as PGConnectionError {
            #expect(error.kind == .connectTimedOut || error.kind == .connectFailed)
        }
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func refusedPortFailsAtOnce() async throws {
        let parameters = PGConnectionParameters(["host": "127.0.0.1", "port": "1", "user": "x", "dbname": "x", "gssencmode": "disable", "sslmode": "disable"])
        do {
            _ = try await PGConnection.connect(parameters, timeout: .seconds(5))
            Issue.record("connected to port 1")
        } catch let error as PGConnectionError {
            #expect(error.kind == .connectFailed)
            #expect(error.message.contains("refused"))
        }
    }

    @Test func parametersHideThePassword() {
        let parameters = PGConnectionParameters(["host": "h", "password": "secret", "sslpassword": "also-secret"])
        #expect(!parameters.description.contains("secret"))
        #expect(parameters.description.contains("host=h"))
        var changed = parameters
        changed.set("host", "other")
        #expect(changed["host"] == "other")
        #expect(changed.entries.filter { $0.keyword == "host" }.count == 1)
        changed.set("password", nil)
        #expect(changed["password"] == nil)
    }
}
