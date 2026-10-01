import Foundation
import Logging
import PGLibpq

/// A leased connection: the libpq connection and the files it was opened with.
struct PostgresLease: Sendable {
    let connection: PGConnection
    let setup: PostgresLibpqSetup
    let openedAt: ContinuousClock.Instant
}

/// The connections of one ``PostgresClient`` (decision D13: up to 4 by default for metadata).
///
/// A lease gets an idle connection (checked first if it has been idle a while) or a new one; when
/// all are leased, it waits. A returned connection is cleaned up first: an unread statement is
/// cancelled and drained, an open transaction rolled back, a broken connection dropped.
/// Reconnecting lets libpq choose among the configured hosts again (`target_session_attrs`), which
/// is how the pool fails over; the change is reported through `hostChanges`.
actor PostgresPool {
    let configuration: PostgresConfiguration
    private let maximum: Int
    private let idleTimeout: Duration
    private let checkoutTimeout: Duration
    private let logger: Logger
    private var idle: [(lease: PostgresLease, since: ContinuousClock.Instant)] = []
    private var leased = 0
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var waiterOrder: [UUID] = []
    private var isClosed = false
    private(set) var currentHost: PostgresHost
    private var hasConnected = false
    /// A connection to `currentHost` was found closed; the next connect explains a move or a
    /// failure as the server being unreachable.
    private var lostCurrentHost = false
    private var hostObservers: [UUID: AsyncStream<PostgresHostChange>.Continuation] = [:]

    /// An idle connection unused this long is checked with an empty query before it is leased.
    private static let checkAfterIdle: Duration = .seconds(30)

    init(configuration: PostgresConfiguration, logger: Logger) {
        self.configuration = configuration
        maximum = max(1, configuration.pool.maximum)
        idleTimeout = .seconds(max(1, configuration.pool.idleTimeoutSeconds))
        checkoutTimeout = .seconds(30)
        self.logger = logger
        currentHost = PostgresHost(host: configuration.unixSocketPath ?? configuration.host, port: configuration.port)
    }

    // MARK: Leasing

    func lease() async throws -> PostgresLease {
        while true {
            guard !isClosed else { throw PostgresError(message: "The connection pool has been closed.") }
            closeExpiredIdle()
            if let entry = idle.popLast() {
                leased += 1
                // A server that closed the connection (it stopped, or failed over) is noticed here,
                // before anything is sent; a new connection then lets libpq choose the host again.
                let alive = await entry.lease.connection.isAlive()
                if alive, ContinuousClock.now - entry.since < Self.checkAfterIdle { return entry.lease }
                if alive, await Self.isHealthy(entry.lease.connection) { return entry.lease }
                leased -= 1
                if !alive { lostCurrentHost = true }
                await entry.lease.connection.close()
                continue
            }
            if leased < maximum {
                leased += 1
                do {
                    return try await open()
                } catch {
                    leased -= 1
                    wakeOneWaiter()
                    throw error
                }
            }
            try await waitForRelease()
        }
    }

    /// Takes a connection back. `reusable` false closes it.
    func release(_ lease: PostgresLease, reusable: Bool = true) async {
        var keep = reusable && !isClosed
        if keep { keep = await Self.clean(lease.connection) }
        leased -= 1
        if keep {
            idle.append((lease, ContinuousClock.now))
        } else {
            await lease.connection.close()
        }
        wakeOneWaiter()
    }

    func close() async {
        isClosed = true
        let connections = idle.map(\.lease.connection)
        idle.removeAll()
        for connection in connections { await connection.close() }
        for id in waiterOrder { waiters.removeValue(forKey: id)?.resume(throwing: PostgresError(message: "The connection pool has been closed.")) }
        waiterOrder.removeAll()
        for observer in hostObservers.values { observer.finish() }
        hostObservers.removeAll()
    }

    // MARK: Opening

    /// Opens a connection with the configured keywords (the password provider is asked each time).
    func open() async throws -> PostgresLease {
        do {
            let password = try await Self.password(for: configuration)
            do {
                return try await connect(configuration, password: password)
            } catch where !configuration.additionalHosts.isEmpty && Self.unreachableReason(error) != nil {
                // libpq stops at a host that accepts the connection and then closes it (a proxy or
                // pooler whose server is gone) instead of trying the next; try each host on its own.
                let hosts = [PostgresHost(host: configuration.host, port: configuration.port)] + configuration.additionalHosts
                for host in hosts {
                    var single = configuration
                    single.host = host.host
                    single.port = host.port
                    single.additionalHosts = []
                    single.loadBalanceHosts = false
                    if let lease = try? await connect(single, password: password) { return lease }
                }
                throw error
            }
        } catch {
            // The server the pool was using went away and none can be reached now: say so, rather
            // than libpq's first-connect wording.
            if hasConnected, let reason = Self.unreachableReason(error) {
                throw PostgresServerUnreachableError(host: currentHost.host, port: currentHost.port, reason: reason)
            }
            throw configuration.connectError(error)
        }
    }

    private func connect(_ configuration: PostgresConfiguration, password: String?) async throws -> PostgresLease {
        let setup = try await configuration.libpqSetup(password: password)
        let connection = try await PGConnection.connect(setup.parameters, timeout: .seconds(max(2, configuration.connectTimeout)))
        await noteHost(of: connection)
        lostCurrentHost = false
        return PostgresLease(connection: connection, setup: setup, openedAt: .now)
    }

    /// libpq's text when a connect failed because the server can't be reached (refused, timed out,
    /// no route), not because it refused the sign-in.
    static func unreachableReason(_ error: any Error) -> String? {
        guard let error = error as? PGConnectionError else { return nil }
        let text = error.message.lowercased()
        let network = ["connection refused", "timeout expired", "timed out", "network is unreachable", "no route to host",
                       "host is down", "server closed the connection", "connection reset"]
        guard error.kind == .connectTimedOut || network.contains(where: text.contains) else { return nil }
        return PostgresConnectionMessages.firstLine(of: error.message, droppingPrefix: true)
    }

    static func password(for configuration: PostgresConfiguration) async throws -> String? {
        if let provider = configuration.passwordProvider { return try await provider().password }
        return configuration.password
    }

    // MARK: Hosts

    func hostChanges() -> AsyncStream<PostgresHostChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PostgresHostChange>.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        hostObservers[id] = continuation
        return stream
    }

    private func removeObserver(_ id: UUID) { hostObservers[id] = nil }

    private func noteHost(of connection: PGConnection) async {
        guard let host = await connection.host else { return }
        let port = await connection.port.flatMap(Int.init) ?? configuration.port
        let reached = PostgresHost(host: host, port: port)
        guard reached != currentHost else { hasConnected = true; return }
        let previous = currentHost
        currentHost = reached
        // The first connection only learns where the pool is; later differences are failovers.
        guard hasConnected else { hasConnected = true; return }
        let reason = lostCurrentHost
            ? "Can't reach the server at \(previous.host):\(previous.port) any more: it may have stopped, or the network is down."
            : "The server at \(previous.host):\(previous.port) could not be used."
        let change = PostgresHostChange(from: previous, to: reached, reason: reason, date: Date())
        logger.notice("Postgres pool moved from \(previous.host):\(previous.port) to \(reached.host):\(reached.port)")
        for observer in hostObservers.values { observer.yield(change) }
    }

    // MARK: Internals

    private func closeExpiredIdle() {
        let now = ContinuousClock.now
        let expired = idle.filter { now - $0.since >= idleTimeout }
        guard !expired.isEmpty else { return }
        idle.removeAll { now - $0.since >= idleTimeout }
        for entry in expired {
            let connection = entry.lease.connection
            Task(name: "postgres-pool-idle-close") { await connection.close() }
        }
    }

    private func waitForRelease() async throws {
        let id = UUID()
        let deadline = checkoutTimeout
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters[id] = continuation
                waiterOrder.append(id)
                Task(name: "postgres-pool-checkout-timeout") { [weak self] in
                    try? await Task.sleep(for: deadline)
                    await self?.failWaiter(id, PostgresError(message: "Timed out waiting for a free connection: all are in use."))
                }
            }
        } onCancel: {
            Task { await self.failWaiter(id, CancellationError()) }
        }
    }

    private func failWaiter(_ id: UUID, _ error: any Error) {
        waiterOrder.removeAll { $0 == id }
        waiters.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func wakeOneWaiter() {
        while !waiterOrder.isEmpty {
            let id = waiterOrder.removeFirst()
            if let waiter = waiters.removeValue(forKey: id) {
                waiter.resume()
                return
            }
        }
    }

    /// An empty query round trip on a connection that has been idle a while.
    private static func isHealthy(_ connection: PGConnection) async -> Bool {
        guard await connection.isOpen else { return false }
        return (try? await connection.execute("")) != nil
    }

    /// Leaves a returned connection as a new one would be: no statement running, no transaction.
    private static func clean(_ connection: PGConnection) async -> Bool {
        guard await connection.isOpen else { return false }
        if await connection.isBusy {
            await PostgresResultStream.finishAbandoned(connection)
            guard await !connection.isBusy else { return false }
        }
        if await connection.transactionStatus != .idle {
            guard let results = try? await connection.execute("ROLLBACK"), results.allSatisfy({ $0.status != .error }) else { return false }
        }
        _ = await connection.takeNotices()
        return await connection.isOpen
    }
}
