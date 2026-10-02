import Foundation
import Logging
import PGLibpq
import Synchronization

/// Transaction state of a ``PostgresSessionConnection``.
public enum PostgresTransactionStatus: Sendable, Equatable {
    /// Not inside a transaction block (every statement commits on its own).
    case idle
    /// Inside `BEGIN … COMMIT`.
    case inTransaction
    /// Inside a transaction block that hit an error; only `ROLLBACK` (or `ROLLBACK TO SAVEPOINT`) helps.
    case failed
}

/// Errors specific to ``PostgresSessionConnection``.
public enum PostgresSessionError: Error, LocalizedError, Sendable, Equatable {
    /// The connection is gone. When `transactionLost` is true a transaction was open and the server
    /// rolled it back — nothing since `BEGIN` was committed.
    case connectionClosed(transactionLost: Bool)

    public var errorDescription: String? {
        switch self {
        case .connectionClosed(let transactionLost):
            return transactionLost
                ? "The connection to the server was lost while a transaction was open. The server rolled the transaction back; nothing since BEGIN was saved."
                : "The connection to the server was closed."
        }
    }
}

/// What running one statement produced. See ``PostgresSessionConnection/execute(_:)``.
public enum PostgresStatementOutcome: Sendable {
    /// A row-returning statement; iterate the rows to completion before running the next statement.
    case rows(PostgresSessionRows)
    /// A command (`INSERT`, `CREATE`, …) with its command tag and any rows it returned.
    case command(WireQueryResult)
}

/// One dedicated, non-pooled connection for interactive use — a query tab, a migration, a script.
///
/// Unlike ``PostgresClient`` (a pool), every call runs on the *same* backend, so `BEGIN … COMMIT`,
/// `SET`, temporary tables, advisory locks and `LISTEN` behave exactly as in `psql`.
/// The session:
/// - reports the transaction state (``transactionStatus``) as the server reports it after every statement,
/// - never reconnects silently: when the connection drops, calls fail with
///   ``PostgresSessionError/connectionClosed(transactionLost:)`` so the user learns whether open work was lost,
/// - notices a server that closes the connection while the session is idle,
/// - can cancel the running statement on the server (``cancel(using:)``),
/// - sends a keep-alive `SELECT 1` only while idle *outside* a transaction, so it never defeats the
///   server's `idle_in_transaction_session_timeout`.
public final class PostgresSessionConnection: Sendable {
    private struct State {
        var transactionStatus: PostgresTransactionStatus = .idle
        var isClosed = false
        var transactionLost = false
        var transactionStartedAt: Date?
        var statementsInTransaction = 0
        var queriesInFlight = 0
        var lastActivity = Date()
        var idleWatch: Task<Void, Never>?
        var keepAlive: Task<Void, Never>?
        var closeWaiters: [CheckedContinuation<Void, Never>] = []
    }

    let pgConnection: PGConnection
    private let setup: PostgresLibpqSetup
    private let logger: Logger
    private let state = Mutex(State())

    /// The backend process ID of this session (as in `pg_stat_activity.pid`).
    public let backendPID: Int32

    /// The server this session is connected to (relevant with several configured hosts).
    public let connectedHost: PostgresHost

    /// Connection-level helpers (DDL builders, …) on this session's backend.
    public let connection: PostgresConnection

    private init(connection: PGConnection, setup: PostgresLibpqSetup, backendPID: Int32, host: PostgresHost, logger: Logger) {
        pgConnection = connection
        self.setup = setup
        self.backendPID = backendPID
        connectedHost = host
        self.logger = logger
        self.connection = PostgresConnection(connection: connection, logger: logger)
    }

    deinit {
        let tasks = state.withLock { ($0.idleWatch, $0.keepAlive) }
        tasks.0?.cancel()
        tasks.1?.cancel()
        let connection = pgConnection
        Task(name: "postgres-session-close") { await connection.close() }
    }

    /// Open a session.
    ///
    /// - Parameter keepAliveInterval: How often to ping while idle outside a transaction, `nil` to disable.
    public static func connect(
        configuration: PostgresConfiguration,
        keepAliveInterval: Duration? = .seconds(30),
        logger: Logger = .init(label: "postgres-kit.session")
    ) async throws -> PostgresSessionConnection {
        do {
            let password = try await PostgresPool.password(for: configuration)
            let setup = try await configuration.libpqSetup(password: password)
            let connection = try await PGConnection.connect(setup.parameters, timeout: .seconds(max(2, configuration.connectTimeout)))
            let host = PostgresHost(
                host: await connection.host ?? configuration.host,
                port: await connection.port.flatMap(Int.init) ?? configuration.port
            )
            let session = PostgresSessionConnection(
                connection: connection, setup: setup, backendPID: await connection.backendPID, host: host, logger: logger
            )
            session.watchWhileIdle()
            if let keepAliveInterval { session.startKeepAlive(every: keepAliveInterval) }
            return session
        } catch {
            throw configuration.connectError(error)
        }
    }

    // MARK: - State

    /// Transaction state, as the server reported it after the last statement (procedures that
    /// commit inside are reflected too).
    public var transactionStatus: PostgresTransactionStatus { state.withLock { $0.transactionStatus } }

    /// Whether the connection is closed (by ``close()``, the server, or the network).
    public var isClosed: Bool { state.withLock { $0.isClosed } }

    /// Whether a statement is currently running (its rows have not been fully consumed).
    public var isQueryInFlight: Bool { state.withLock { $0.queriesInFlight > 0 } }

    /// Whether the connection closed while a transaction was open (the server rolled it back).
    public var transactionWasLost: Bool { state.withLock { $0.isClosed && $0.transactionLost } }

    /// When the open transaction began (its `BEGIN` finished), `nil` outside a transaction.
    public var transactionStartedAt: Date? { state.withLock { $0.transactionStartedAt } }

    /// Statements that succeeded inside the open transaction, not counting `BEGIN` (for a close
    /// prompt: "open for 12 minutes, 3 statements").
    public var statementsInTransaction: Int { state.withLock { $0.statementsInTransaction } }

    // MARK: - Queries

    /// Run SQL and stream its rows (with several statements, the last result set's).
    public func query(_ sql: String) async throws -> PostgresSessionRows {
        try await startStatement { try await $0.send(sql) }
    }

    /// Run one statement with bind parameters (`$1`, `$2`, …) and stream its rows.
    public func query(_ sql: String, binds: [PostgresBind]) async throws -> PostgresSessionRows {
        try await startStatement { try await $0.send(sql, parameters: binds.map(\.parameter)) }
    }

    /// Run one statement and collect all rows plus the command tag (`UPDATE 3`, `CREATE TABLE`, …).
    public func queryResult(_ sql: String) async throws -> PostgresQueryResult {
        let rows = try await query(sql)
        var collected: [PostgresRow] = []
        for try await row in rows { collected.append(row) }
        return PostgresQueryResult(metadata: PostgresQueryMetadata(tag: rows.stream.commandTag ?? ""), rows: collected)
    }

    /// Run one statement, streaming row-returning statements and collecting the command tag for the rest.
    public func execute(_ statement: String) async throws -> PostgresStatementOutcome {
        if PostgresSQLSplitter.returnsRows(statement) {
            return .rows(try await query(statement))
        }
        return .command(try await queryResult(statement))
    }

    /// Run a script statement by statement (see ``PostgresSQLSplitter``), stopping at the first error.
    ///
    /// `onStatement` must consume `.rows` before returning. Errors are rethrown as
    /// ``PostgresScriptError`` so the caller knows which statement failed.
    public func executeScript(
        _ sql: String,
        onStatement: (PostgresSQLStatement, PostgresStatementOutcome) async throws -> Void
    ) async throws {
        for statement in PostgresSQLSplitter.split(sql) {
            do {
                try await onStatement(statement, try await execute(statement.text))
            } catch {
                throw PostgresScriptError(statement: statement, underlying: error)
            }
        }
    }

    /// The exact transaction state, as the server reported it after the last statement (no round trip).
    @discardableResult
    public func refreshTransactionStatus() async throws -> PostgresTransactionStatus {
        try throwIfClosed()
        let status = Self.status(await pgConnection.transactionStatus) ?? transactionStatus
        state.withLock { Self.apply(status, statementSucceeded: false, to: &$0) }
        return status
    }

    // MARK: - Cancel and timeouts

    /// Cancel the statement this session is running. libpq sends the cancel request over its own
    /// short connection to the same server; the statement then fails with SQLSTATE `57014`.
    ///
    /// - Parameter client: Ignored (kept for callers that passed a pool before).
    /// - Returns: `false` if nothing was running.
    @discardableResult
    public func cancel(using client: PostgresClient? = nil) async throws -> Bool {
        guard isQueryInFlight, !isClosed else { return false }
        do {
            try await pgConnection.cancel()
            return true
        } catch {
            throw PostgresError.from(error)
        }
    }

    /// Set this session's `statement_timeout`. `nil` restores the connection's default (the configured
    /// ``PostgresConfiguration/statementTimeout`` or the server's), `.zero` disables the timeout.
    public func setStatementTimeout(_ timeout: Duration?) async throws {
        _ = try await queryResult(Self.timeoutStatement("statement_timeout", timeout))
    }

    /// Set this session's `lock_timeout`. `nil` restores the connection's default, `.zero` disables it.
    public func setLockTimeout(_ timeout: Duration?) async throws {
        _ = try await queryResult(Self.timeoutStatement("lock_timeout", timeout))
    }

    static func timeoutStatement(_ parameter: String, _ timeout: Duration?) -> String {
        guard let timeout else { return "RESET \(parameter)" }
        let parts = timeout.components
        let milliseconds = max(0, parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
        return "SET \(parameter) = \(milliseconds)"
    }

    // MARK: - Lifecycle

    /// Close the connection. An open transaction is rolled back by the server.
    public func close() async {
        let tasks = state.withLock { state -> (Task<Void, Never>?, Task<Void, Never>?) in
            state.isClosed = true
            return (state.idleWatch, state.keepAlive)
        }
        tasks.0?.cancel()
        tasks.1?.cancel()
        await pgConnection.close()
        markClosed(lost: false)
    }

    /// Suspend until the connection closes.
    public func waitForClose() async {
        await withCheckedContinuation { continuation in
            let closed = state.withLock { state -> Bool in
                if state.isClosed { return true }
                state.closeWaiters.append(continuation)
                return false
            }
            if closed { continuation.resume() }
        }
    }

    // MARK: - Internals

    /// Stops the idle watch, reads away anything left from an abandoned statement, sends, and
    /// returns the rows; finishing them updates the transaction state and restarts the watch.
    private func startStatement(_ send: (PGConnection) async throws -> Void) async throws -> PostgresSessionRows {
        try throwIfClosed()
        await stopIdleWatch()
        state.withLock { state in
            state.queriesInFlight += 1
            state.lastActivity = Date()
        }
        do {
            if await pgConnection.isBusy {
                await PostgresResultStream.finishAbandoned(pgConnection)
            }
            try await send(pgConnection)
        } catch {
            let mapped = await finishStatement(error: error)
            throw mapped
        }
        let stream = PostgresResultStream(connection: pgConnection, mapError: { $0 }) { [weak self] _, error, _ in
            _ = await self?.finishStatement(error: error)
        }
        do {
            try await stream.awaitFirstResult()
        } catch {
            throw await finishStatementError(error)
        }
        return PostgresSessionRows(stream: stream, session: self)
    }

    /// Called once per statement: reads the transaction state from the server, maps the error.
    @discardableResult
    fileprivate func finishStatement(error: (any Error)?) async -> any Error {
        let mapped = error.map { PostgresError.from($0) }
        let connectionLost = await !pgConnection.isOpen || (mapped?.isConnectionLost ?? false)
        let status = Self.status(await pgConnection.transactionStatus)
        state.withLock { state in
            state.queriesInFlight = max(0, state.queriesInFlight - 1)
            state.lastActivity = Date()
            if let status, !connectionLost { Self.apply(status, statementSucceeded: error == nil, to: &state) }
        }
        if connectionLost {
            let lost = state.withLock { $0.transactionStatus != .idle }
            markClosed(lost: lost)
            return PostgresSessionError.connectionClosed(transactionLost: lost)
        }
        if !isQueryInFlight { watchWhileIdle() }
        return mapped ?? PostgresError(message: "")
    }

    private static func status(_ status: PGConnection.TransactionStatus) -> PostgresTransactionStatus? {
        switch status {
        case .idle: .idle
        case .inTransaction: .inTransaction
        case .failedTransaction: .failed
        case .active, .unknown: nil
        }
    }

    private static func apply(_ status: PostgresTransactionStatus, statementSucceeded: Bool, to state: inout State) {
        let wasIdle = state.transactionStatus == .idle
        state.transactionStatus = status
        switch status {
        case .idle:
            state.transactionStartedAt = nil
            state.statementsInTransaction = 0
        case .inTransaction, .failed:
            if wasIdle {
                state.transactionStartedAt = Date()
                state.statementsInTransaction = 0
            } else if statementSucceeded, status == .inTransaction {
                state.statementsInTransaction += 1
            }
        }
    }

    private func throwIfClosed() throws {
        let closed = state.withLock { state -> Bool? in state.isClosed ? state.transactionLost : nil }
        if let lost = closed { throw PostgresSessionError.connectionClosed(transactionLost: lost) }
    }

    private func markClosed(lost: Bool) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            if !state.isClosed || lost { state.transactionLost = state.transactionLost || lost }
            state.isClosed = true
            state.keepAlive?.cancel()
            defer { state.closeWaiters.removeAll() }
            return state.closeWaiters
        }
        if lost { logger.warning("Session connection \(backendPID) closed with an open transaction") }
        waiters.forEach { $0.resume() }
    }

    /// While idle, waits on the socket so a server that closes the connection is noticed now,
    /// not at the next statement.
    private func watchWhileIdle() {
        let connection = pgConnection
        let task = Task(name: "postgres-session-idle-watch") { [weak self] in
            do {
                while !Task.isCancelled { _ = try await connection.waitWhileIdle() }
            } catch let error as PGConnectionError where error.kind == .connectionLost {
                guard let self else { return }
                let lost = self.state.withLock { $0.transactionStatus != .idle }
                self.markClosed(lost: lost)
            } catch {}
        }
        let previous = state.withLock { state -> Task<Void, Never>? in
            defer { state.idleWatch = task }
            return state.idleWatch
        }
        previous?.cancel()
    }

    private func stopIdleWatch() async {
        let watch = state.withLock { state -> Task<Void, Never>? in
            defer { state.idleWatch = nil }
            return state.idleWatch
        }
        watch?.cancel()
        await watch?.value
    }

    private func startKeepAlive(every interval: Duration) {
        let task = Task(name: "postgres-session-keepalive") { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                let due = self.state.withLock { state in
                    !state.isClosed && state.queriesInFlight == 0 && state.transactionStatus == .idle
                        && Date().timeIntervalSince(state.lastActivity) >= Double(interval.components.seconds)
                }
                if due { _ = try? await self.queryResult("SELECT 1") }
            }
        }
        state.withLock { $0.keepAlive = task }
    }
}

/// Error from ``PostgresSessionConnection/executeScript(_:onStatement:)`` naming the failed statement.
public struct PostgresScriptError: Error, LocalizedError, @unchecked Sendable {
    public let statement: PostgresSQLStatement
    public let underlying: any Error

    public var errorDescription: String? {
        "Statement \(statement.index + 1) failed: \((underlying as? LocalizedError)?.errorDescription ?? String(describing: underlying))"
    }
}

/// Rows of one statement on a ``PostgresSessionConnection``.
///
/// Iterate to the end (or drop the sequence) before the session's next statement; errors thrown while
/// iterating are the session's (``PostgresSessionError/connectionClosed(transactionLost:)`` when the
/// connection broke).
public struct PostgresSessionRows: AsyncSequence, Sendable {
    public typealias Element = PostgresRow
    let stream: PostgresResultStream
    let session: PostgresSessionConnection

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: PostgresRows(stream: stream).makeAsyncIterator(), session: session)
    }

    /// Collect all rows into memory.
    public func collect() async throws -> [PostgresRow] {
        var rows: [PostgresRow] = []
        for try await row in self { rows.append(row) }
        return rows
    }

    /// The column names and types, as soon as the server described them (also with no rows).
    public func columns() async throws -> [PostgresColumn] {
        do { return try await stream.columns() } catch { throw await session.finishStatementError(error) }
    }

    /// The results as libpq delivers them, for a reader that handles whole chunks (the result
    /// grid's spool). Don't mix with row iteration.
    public var chunks: PostgresChunks { PostgresChunks(stream: stream) }

    /// The command tag once the rows have been read (`SELECT 3`).
    public var commandTag: String? { stream.commandTag }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: PostgresRows.AsyncIterator
        let session: PostgresSessionConnection

        public mutating func next() async throws -> PostgresRow? {
            do {
                return try await base.next()
            } catch {
                throw await session.finishStatementError(error)
            }
        }
    }
}

extension PostgresSessionConnection {
    /// The error a reader sees: a lost connection becomes ``PostgresSessionError/connectionClosed(transactionLost:)``.
    fileprivate func finishStatementError(_ error: any Error) async -> any Error {
        if isClosed { return PostgresSessionError.connectionClosed(transactionLost: transactionWasLost) }
        let mapped = PostgresError.from(error)
        if mapped.isConnectionLost {
            return PostgresSessionError.connectionClosed(transactionLost: transactionWasLost)
        }
        return mapped
    }
}
