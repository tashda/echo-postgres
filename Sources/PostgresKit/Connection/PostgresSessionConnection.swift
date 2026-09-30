import Foundation
import Logging
import NIOConcurrencyHelpers
import PostgresNIO
import PostgresWire

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
/// - tracks the transaction state (``transactionStatus``) from the statements it runs,
/// - never reconnects silently: when the connection drops, calls fail with
///   ``PostgresSessionError/connectionClosed(transactionLost:)`` so the user learns whether open work was lost,
/// - can cancel the running statement on the server (``cancel()``),
/// - sends a keep-alive `SELECT 1` only while idle *outside* a transaction, so it never defeats the
///   server's `idle_in_transaction_session_timeout`.
public final class PostgresSessionConnection: @unchecked Sendable {
    private struct State {
        var transactionStatus: PostgresTransactionStatus = .idle
        var isClosed = false
        var transactionLost = false
        var transactionStartedAt: Date?
        var statementsInTransaction = 0
        var queriesInFlight = 0
        var lastActivity = Date()
    }

    private let nioConnection: PostgresNIO.PostgresConnection
    private let wireConfiguration: PostgresWireConfiguration
    private let logger: Logger
    private let state = NIOLockedValueBox(State())
    private var keepAliveTask: Task<Void, Never>?

    /// The backend process ID of this session (as in `pg_stat_activity.pid`).
    public let backendPID: Int32

    /// The server this session is connected to (relevant with several configured hosts).
    public var connectedHost: PostgresHost {
        PostgresHost(host: wireConfiguration.unixSocketPath ?? wireConfiguration.host, port: wireConfiguration.port)
    }

    /// Wrapper for the PostgresKit connection-level helpers (DDL builders, notifications, …).
    public let connection: PostgresConnection

    private init(nioConnection: PostgresNIO.PostgresConnection, backendPID: Int32, wireConfiguration: PostgresWireConfiguration, logger: Logger) {
        self.nioConnection = nioConnection
        self.backendPID = backendPID
        self.wireConfiguration = wireConfiguration
        self.logger = logger
        self.connection = PostgresConnection(
            wireConnection: WireConnection(nioConnection),
            logger: logger,
            cache: StatementCache(capacity: 64),
            serverCache: PreparedServerCache(capacity: 32)
        )
    }

    deinit {
        keepAliveTask?.cancel()
        let connection = nioConnection
        if !state.withLockedValue({ $0.isClosed }) {
            Task { try? await connection.close() }
        }
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
            let opened = try await PostgresWireClient.openSelectedConnection(configuration: configuration.makeWireConfiguration(), logger: logger)
            let nioConnection = opened.connection
            // Keep the resolved configuration: cancels must go to the same host with the same TLS mode.
            let wireConfiguration = opened.configuration
            let pid: Int32
            do {
                pid = try await Self.queryBackendPID(nioConnection, logger: logger)
            } catch {
                try? await nioConnection.close()
                throw error
            }
            let session = PostgresSessionConnection(nioConnection: nioConnection, backendPID: pid, wireConfiguration: wireConfiguration, logger: logger)
            session.watchForClose()
            if let keepAliveInterval { session.startKeepAlive(every: keepAliveInterval) }
            return session
        } catch {
            throw PostgresError.from(error)
        }
    }

    // MARK: - State

    /// Transaction state as tracked from the statements run on this session.
    ///
    /// Statements that manage transactions internally (a procedure that commits) are not visible here;
    /// use ``refreshTransactionStatus()`` when an exact answer matters.
    public var transactionStatus: PostgresTransactionStatus { state.withLockedValue { $0.transactionStatus } }

    /// Whether the connection is closed (by ``close()``, the server, or the network).
    public var isClosed: Bool { state.withLockedValue { $0.isClosed } }

    /// Whether a statement is currently running (its rows have not been fully consumed).
    public var isQueryInFlight: Bool { state.withLockedValue { $0.queriesInFlight > 0 } }

    /// Whether the connection closed while a transaction was open (the server rolled it back).
    public var transactionWasLost: Bool { state.withLockedValue { $0.isClosed && $0.transactionLost } }

    /// When the open transaction began (its `BEGIN` finished), `nil` outside a transaction.
    public var transactionStartedAt: Date? { state.withLockedValue { $0.transactionStartedAt } }

    /// Statements that succeeded inside the open transaction, not counting `BEGIN` (for a close
    /// prompt: "open for 12 minutes, 3 statements").
    public var statementsInTransaction: Int { state.withLockedValue { $0.statementsInTransaction } }

    // MARK: - Queries

    /// Run one statement and stream its rows.
    public func query(_ sql: String) async throws -> PostgresSessionRows {
        try await query(WireQuery(sql: sql))
    }

    /// Run one statement with bind parameters (`$1`, `$2`, …) and stream its rows.
    public func query(_ sql: String, binds: [PGData]) async throws -> PostgresSessionRows {
        var bindings = PGBindings()
        for bind in binds { bindings.append(bind) }
        return try await query(WireQuery(sql: sql, binds: bindings))
    }

    private func query(_ query: WireQuery, allowFallback: Bool = true) async throws -> PostgresSessionRows {
        let effect = PostgresSQLSplitter.transactionEffect(of: query.sql)
        let canFallBack = allowFallback && query.binds == nil && transactionStatus == .idle
        try beginQuery()
        let token = QueryToken(session: self, effect: effect)
        do {
            let rows = try await nioConnection.query(query.asPostgresQuery(), logger: logger)
            let sql = query.sql
            let fallback: PostgresSessionRows.Fallback? = canFallBack
                ? { @Sendable [weak self] error in await self?.textFallbackRows(for: sql, after: error) }
                : nil
            return PostgresSessionRows(base: rows, token: token, fallback: fallback)
        } catch {
            token.finish(error: error)
            if canFallBack, let rows = await textFallbackRows(for: query.sql, after: error) { return rows }
            throw mapError(error)
        }
    }

    /// Rows of the text-cast rewrite when `error` is "no binary output function" (see `+TextFallback`).
    fileprivate func textFallbackRows(for sql: String, after error: any Error) async -> PostgresSessionRows? {
        guard Self.isMissingBinaryOutput(error), let rewritten = try? await textFallbackSQL(for: sql) else { return nil }
        return try? await query(WireQuery(sql: rewritten), allowFallback: false)
    }

    /// Run one statement and collect all rows plus the command tag (`UPDATE 3`, `CREATE TABLE`, …).
    public func queryResult(_ sql: String) async throws -> WireQueryResult {
        let effect = PostgresSQLSplitter.transactionEffect(of: sql)
        let canFallBack = transactionStatus == .idle
        try beginQuery()
        let token = QueryToken(session: self, effect: effect)
        do {
            let result = try await nioConnection.query(PostgresQuery(unsafeSQL: sql), logger: logger).get()
            token.finish(error: nil)
            return result
        } catch {
            token.finish(error: error)
            if canFallBack, Self.isMissingBinaryOutput(error), let rewritten = try? await textFallbackSQL(for: sql) {
                return try await queryResult(rewritten)
            }
            throw mapError(error)
        }
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

    /// Ask the server for the exact transaction state (two round trips, no side effects).
    ///
    /// Sets a transaction-local placeholder setting and reads it back in a second statement: inside a
    /// transaction block the value survives to the next statement, in autocommit it does not, and in a
    /// failed transaction the first statement is rejected with SQLSTATE `25P02`.
    @discardableResult
    public func refreshTransactionStatus() async throws -> PostgresTransactionStatus {
        let token = UUID().uuidString
        let status: PostgresTransactionStatus
        do {
            _ = try await probeQuery("SELECT set_config('postgres_wire.transaction_probe', '\(token)', true)")
            let result = try await probeQuery("SELECT current_setting('postgres_wire.transaction_probe', true)")
            let value = try result.rows.first?.decode(String?.self) ?? nil
            status = value == token ? .inTransaction : .idle
        } catch let error as PostgresError where error.sqlState == "25P02" {
            status = .failed
        }
        state.withLockedValue { state in
            state.transactionStatus = status
            if status == .idle {
                state.transactionStartedAt = nil
                state.statementsInTransaction = 0
            } else if state.transactionStartedAt == nil {
                state.transactionStartedAt = Date()
            }
        }
        return status
    }

    /// Runs a statement without letting its outcome change the tracked transaction state.
    func probeQuery(_ sql: String) async throws -> WireQueryResult {
        try beginQuery()
        defer { state.withLockedValue { $0.queriesInFlight = max(0, $0.queriesInFlight - 1) } }
        do {
            return try await nioConnection.query(PostgresQuery(unsafeSQL: sql), logger: logger).get()
        } catch {
            throw mapError(error)
        }
    }

    // MARK: - Cancel and timeouts

    /// Cancel the statement this session is running (`pg_cancel_backend`), sent over a short-lived
    /// side connection so it works while this one is busy. The statement fails with SQLSTATE `57014`.
    ///
    /// - Parameter client: A pool to send the cancel through instead of opening a side connection.
    /// - Returns: `false` if nothing was running or the server did not signal the backend.
    @discardableResult
    public func cancel(using client: PostgresClient? = nil) async throws -> Bool {
        guard isQueryInFlight, !isClosed else { return false }
        do {
            if let client {
                return try await client.cancelBackend(pid: backendPID)
            }
            let side = try await PostgresWireClient.openConnection(configuration: wireConfiguration, logger: logger)
            defer { Task { try? await side.close() } }
            var binds = PostgresBindings()
            binds.append(backendPID)
            let rows = try await side.query(PostgresQuery(unsafeSQL: "SELECT pg_cancel_backend($1)", binds: binds), logger: logger)
            for try await signalled in rows.decode(Bool.self) { return signalled }
            return false
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
        keepAliveTask?.cancel()
        state.withLockedValue { $0.isClosed = true }
        try? await nioConnection.close()
    }

    /// Suspend until the connection closes.
    public func waitForClose() async {
        _ = try? await nioConnection.closeFuture.get()
    }

    // MARK: - Internals

    private func beginQuery() throws {
        try state.withLockedValue { state in
            if state.isClosed { throw PostgresSessionError.connectionClosed(transactionLost: state.transactionLost) }
            state.queriesInFlight += 1
            state.lastActivity = Date()
        }
    }

    /// Called exactly once per query when it completes, fails or its rows are abandoned.
    fileprivate func queryFinished(effect: PostgresTransactionEffect, error: (any Error)?) {
        state.withLockedValue { state in
            state.queriesInFlight = max(0, state.queriesInFlight - 1)
            state.lastActivity = Date()
            guard !state.isClosed else { return }
            if error == nil {
                switch effect {
                case .begin, .chain:
                    state.transactionStatus = .inTransaction
                    state.transactionStartedAt = Date()
                    state.statementsInTransaction = 0
                case .rollbackToSavepoint: state.transactionStatus = .inTransaction
                case .end: state.transactionStatus = .idle
                case .none: if state.transactionStatus != .idle { state.statementsInTransaction += 1 }
                }
            } else if effect == .end {
                // A failed COMMIT still ends the transaction block (it is rolled back).
                state.transactionStatus = .idle
            } else if state.transactionStatus != .idle {
                state.transactionStatus = .failed
            }
            if state.transactionStatus == .idle {
                state.transactionStartedAt = nil
                state.statementsInTransaction = 0
            }
        }
    }

    private func mapError(_ error: any Error) -> any Error {
        let lost = state.withLockedValue { state -> Bool? in state.isClosed ? state.transactionLost : nil }
        if let lost { return PostgresSessionError.connectionClosed(transactionLost: lost) }
        let mapped = PostgresError.from(error)
        if Self.isMissingBinaryOutput(mapped), mapped.hint == nil {
            return mapped.withHint(Self.binaryOutputHint)
        }
        return mapped
    }

    fileprivate func mapIterationError(_ error: any Error) -> any Error {
        mapError(error)
    }

    private func watchForClose() {
        nioConnection.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            let lost = self.state.withLockedValue { state -> Bool in
                if !state.isClosed, state.transactionStatus != .idle { state.transactionLost = true }
                state.isClosed = true
                return state.transactionLost
            }
            if lost { self.logger.warning("Session connection \(self.backendPID) closed with an open transaction") }
            self.keepAliveTask?.cancel()
        }
    }

    private func startKeepAlive(every interval: Duration) {
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                let due = self.state.withLockedValue { state in
                    !state.isClosed && state.queriesInFlight == 0 && state.transactionStatus == .idle
                        && Date().timeIntervalSince(state.lastActivity) >= Double(interval.components.seconds)
                }
                if due { _ = try? await self.queryResult("SELECT 1") }
            }
        }
    }

    private static func queryBackendPID(_ connection: PostgresNIO.PostgresConnection, logger: Logger) async throws -> Int32 {
        let rows = try await connection.query("SELECT pg_backend_pid()", logger: logger)
        for try await pid in rows.decode(Int32.self) { return pid }
        throw PostgresError(message: "Could not read the backend process ID")
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

/// Tracks one in-flight query; reports completion to the session exactly once.
final class QueryToken: @unchecked Sendable {
    private weak var session: PostgresSessionConnection?
    private let effect: PostgresTransactionEffect
    private let finished = NIOLockedValueBox(false)

    init(session: PostgresSessionConnection, effect: PostgresTransactionEffect) {
        self.session = session
        self.effect = effect
    }

    func finish(error: (any Error)?) {
        let first = finished.withLockedValue { done -> Bool in
            defer { done = true }
            return !done
        }
        if first { session?.queryFinished(effect: effect, error: error) }
    }

    func mapError(_ error: any Error) -> any Error {
        session?.mapIterationError(error) ?? error
    }

    deinit {
        // Rows abandoned without being consumed: the statement is no longer tracked as running.
        finish(error: nil)
    }
}

/// Rows of one statement on a ``PostgresSessionConnection``.
///
/// Iterate to the end (or drop the sequence) before the session's next statement; errors thrown while
/// iterating update the session's transaction state.
public struct PostgresSessionRows: AsyncSequence, Sendable {
    public typealias Element = PostgresRow
    typealias Fallback = @Sendable (any Error) async -> PostgresSessionRows?

    let base: WireRowSequence
    let token: QueryToken
    var fallback: Fallback? = nil

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), token: token, fallback: fallback)
    }

    /// Collect all rows into memory.
    public func collect() async throws -> [PostgresRow] {
        var rows: [PostgresRow] = []
        for try await row in self { rows.append(row) }
        return rows
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: WireRowSequence.AsyncIterator
        var token: QueryToken
        var fallback: Fallback?
        var yieldedRow = false

        public mutating func next() async throws -> PostgresRow? {
            do {
                guard let row = try await base.next() else {
                    token.finish(error: nil)
                    return nil
                }
                yieldedRow = true
                return row
            } catch {
                token.finish(error: error)
                let reported = token.mapError(error)
                // "No binary output function" arrives before the first row: retry with text casts.
                if !yieldedRow, let fallback {
                    self.fallback = nil
                    if let rows = await fallback(error) {
                        base = rows.base.makeAsyncIterator()
                        token = rows.token
                        return try await next()
                    }
                }
                throw reported
            }
        }
    }
}
