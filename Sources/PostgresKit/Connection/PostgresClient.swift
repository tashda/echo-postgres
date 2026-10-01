import Foundation
import Logging
import PGLibpq
import Synchronization

/// Primary high-level client for PostgreSQL: a small pool of libpq connections to one database,
/// with typed APIs for metadata, administration, security and the rest (``metadata``, ``admin`` …).
///
/// Each call leases a connection for its duration. For `BEGIN … COMMIT`, `SET`, temporary tables
/// and other session state use ``withTransaction(isolation:readOnly:_:)`` or a
/// ``PostgresSessionConnection``.
public final class PostgresClient: Sendable {
    let pool: PostgresPool
    let logger: Logger
    private let host: Mutex<PostgresHost>
    private let notifierBox = Mutex<PostgresNotifier?>(nil)
    private let monitorBox = Mutex<PostgresActivityMonitor?>(nil)
    let typeNameCache = Mutex<[UInt32: String]>([:])

    /// The activity monitor (it keeps the last snapshot to compute rates), created on first use.
    var activityMonitor: PostgresActivityMonitor {
        monitorBox.withLock { box in
            if let monitor = box { return monitor }
            let monitor = PostgresActivityMonitor(client: self)
            box = monitor
            return monitor
        }
    }

    /// LISTEN/NOTIFY support, created on first use. It references this client weakly.
    var notifierActor: PostgresNotifier {
        notifierBox.withLock { box in
            if let notifier = box { return notifier }
            let notifier = PostgresNotifier(client: self, logger: logger)
            box = notifier
            return notifier
        }
    }

    private init(pool: PostgresPool, host: PostgresHost, logger: Logger) {
        self.pool = pool
        self.host = Mutex(host)
        var logger = logger
        logger[metadataKey: "component"] = "PostgresClient"
        self.logger = logger
    }

    deinit {
        let pool = self.pool
        Task(name: "postgres-client-close") { await pool.close() }
    }

    /// Connects (one connection is opened now, so a wrong address or password fails here).
    public static func connect(
        configuration: PostgresConfiguration,
        logger: Logger = .init(label: "postgres-kit")
    ) async throws -> PostgresClient {
        let pool = PostgresPool(configuration: configuration, logger: logger)
        let first = try await pool.lease()
        await pool.release(first)
        let client = PostgresClient(pool: pool, host: await pool.currentHost, logger: logger)
        let changes = await pool.hostChanges()
        Task(name: "postgres-client-host") { [weak client] in
            for await change in changes { client?.host.withLock { $0 = change.to } }
        }
        return client
    }

    /// Closes every connection. Calls after this fail.
    public func close() {
        let pool = self.pool
        Task(name: "postgres-client-close") { await pool.close() }
    }

    /// Closes every connection and waits until they are closed.
    public func shutdown() async {
        await pool.close()
    }

    /// The server this client's connections reach now. With several configured hosts it can change
    /// after a failover; ``hostChanges()`` reports each change.
    public var currentHost: PostgresHost { host.withLock { $0 } }

    /// Reports each time the pool fails over to another configured host.
    public func hostChanges() -> AsyncStream<PostgresHostChange> {
        let (stream, continuation) = AsyncStream<PostgresHostChange>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let pool = self.pool
        let relay = Task(name: "postgres-client-host-changes") {
            for await change in await pool.hostChanges() { continuation.yield(change) }
            continuation.finish()
        }
        continuation.onTermination = { _ in relay.cancel() }
        return stream
    }

    /// Connects to every configured host at once and reports whether each is a primary or a
    /// standby (for a connection test with several servers). Each connection is closed again.
    public static func probeHosts(
        configuration: PostgresConfiguration,
        logger: Logger = .init(label: "postgres-kit")
    ) async -> [PostgresHostProbe] {
        let hosts = [PostgresHost(host: configuration.host, port: configuration.port)] + configuration.additionalHosts
        let password: String?
        do {
            password = try await PostgresPool.password(for: configuration)
        } catch {
            return hosts.map { PostgresHostProbe(host: $0, role: nil, error: PostgresError.from(error), elapsed: .zero) }
        }
        return await withTaskGroup(of: (Int, PostgresHostProbe).self) { group in
            for (index, host) in hosts.enumerated() {
                group.addTask {
                    let clock = ContinuousClock(), start = clock.now
                    var single = configuration
                    single.host = host.host
                    single.port = host.port
                    single.additionalHosts = []
                    single.targetSessionAttributes = .any
                    single.loadBalanceHosts = false
                    do {
                        let setup = try await single.libpqSetup(password: password)
                        let connection = try await PGConnection.connect(setup.parameters, timeout: .seconds(max(2, single.connectTimeout)))
                        defer { Task { await connection.close() } }
                        let inRecovery = try await connection.execute("SELECT pg_is_in_recovery()").first?.string(row: 0, column: 0)
                        withExtendedLifetime(setup) {}
                        return (index, PostgresHostProbe(host: host, role: inRecovery == "t" ? .standby : .primary, error: nil, elapsed: clock.now - start))
                    } catch {
                        return (index, PostgresHostProbe(host: host, role: nil, error: PostgresError.from(error), elapsed: clock.now - start))
                    }
                }
            }
            var probes: [(Int, PostgresHostProbe)] = []
            for await probe in group { probes.append(probe) }
            return probes.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Borrows one connection for several steps. Rows returned from `body` unread keep the
    /// connection until they have been read (or dropped).
    public func withConnection<T>(
        _ body: (PostgresConnection) async throws -> T
    ) async throws -> T {
        let lease = try await pool.lease()
        let connection = PostgresConnection(connection: lease.connection, logger: logger)
        do {
            let result = try await body(connection)
            // Rows returned from `body` and not read yet keep the connection until they are.
            if let unread = connection.lastRows.withLock({ $0.stream }), !unread.isFinished {
                let pool = self.pool
                await unread.whenFinished { error in
                    await pool.release(lease, reusable: !((error.map(PostgresError.from))?.isConnectionLost ?? false))
                }
                return result
            }
            await pool.release(lease)
            return result
        } catch {
            await pool.release(lease, reusable: !((error as? PostgresError)?.isConnectionLost ?? false))
            throw PostgresError.fromDriver(error)
        }
    }

    /// Runs `body` inside `BEGIN … COMMIT` on one leased connection.
    ///
    /// Commits when `body` returns and rolls back when it throws (including cancellation). Every
    /// statement inside `body` must use the `connection` it is given — the client itself is a pool.
    public func withTransaction<T>(
        isolation: PostgresIsolationLevel? = nil,
        readOnly: Bool = false,
        _ body: (PostgresConnection) async throws -> T
    ) async throws -> T {
        try await withConnection { connection in
            var begin = "BEGIN"
            if let isolation { begin += " ISOLATION LEVEL \(isolation.rawValue)" }
            if readOnly { begin += " READ ONLY" }
            _ = try await connection.executeDDL(begin)
            do {
                let result = try await body(connection)
                _ = try await connection.executeDDL("COMMIT")
                return result
            } catch {
                _ = try? await connection.executeDDL("ROLLBACK")
                throw error
            }
        }
    }

    /// Runs one statement on a leased connection and streams its rows; the connection goes back
    /// to the pool when the rows have been read (or dropped).
    public func query(_ sql: String, binds: [PostgresBind] = []) async throws -> PostgresRows {
        let lease = try await pool.lease()
        let pool = self.pool
        do {
            if binds.isEmpty {
                try await lease.connection.send(sql)
            } else {
                try await lease.connection.send(sql, parameters: binds.map(\.parameter))
            }
        } catch {
            await pool.release(lease, reusable: false)
            throw PostgresError.from(error)
        }
        return PostgresRows(stream: PostgresResultStream(connection: lease.connection, completion: { _, error, _ in
            await pool.release(lease, reusable: !((error as? PostgresError)?.isConnectionLost ?? false))
        }))
    }

    /// Ask the server to cancel what backend `pid` is running (`pg_cancel_backend`).
    ///
    /// - Returns: `false` when the server did not signal the backend (for example, it no longer exists).
    @discardableResult
    public func cancelBackend(pid: Int32) async throws -> Bool {
        try await withConnection { connection in
            let rows = try await connection.query("SELECT pg_cancel_backend($1)", binds: [.int32(pid)])
            for try await signalled in rows.decode(Bool.self) { return signalled }
            return false
        }
    }

    /// A value as a statement parameter.
    func bind(_ value: Any) throws -> PostgresBind {
        guard let encodable = value as? any PostgresEncodable else { throw PostgresError.encodingError(type: type(of: value)) }
        return try encodable.postgresBind()
    }

    /// Runs a statement and returns the number of rows it returned.
    @discardableResult
    func executeDDL(_ sql: String) async throws -> Int {
        try await withConnection { try await $0.executeDDL(sql) }
    }

    /// Quote an identifier; schema-qualified names like "app.users" become "app"."users".
    func quoteIdentifier(_ identifier: String) -> String {
        PostgresQuoting.quoteQualifiedIdentifier(identifier)
    }

    /// Quote a single identifier (no schema splitting).
    func quoteSimpleIdentifier(_ identifier: String) -> String {
        PostgresQuoting.quoteIdentifier(identifier)
    }

    /// Quote a literal string.
    func quoteLiteral(_ literal: String) -> String {
        PostgresQuoting.quoteLiteral(literal)
    }
}
