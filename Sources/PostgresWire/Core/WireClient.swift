import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import PostgresNIO

public final class PostgresWireClient: @unchecked Sendable {
    private struct Pool {
        let client: PostgresClient
        let runTask: Task<Void, Never>
        let expiresAt: Date?
    }

    /// Pools are replaced (not mutated) when a short-lived credential is about to expire.
    private let pools: NIOLockedValueBox<Pool>
    private let rotation = NIOLockedValueBox<Task<Void, any Error>?>(nil)
    private let configuration: PostgresWireConfiguration
    /// The configuration in use: the selected host, the resolved `sslmode` and the current password.
    public let resolvedConfiguration: PostgresWireConfiguration
    let logger: Logger

    /// Credentials are refreshed this long before they expire.
    private static let rotationMargin: TimeInterval = 120
    /// A replaced pool keeps running this long so leases taken from it can finish.
    private static let retiredPoolGrace: Duration = .seconds(900)

    private init(configuration: PostgresWireConfiguration, resolved: PostgresWireConfiguration, credential: PostgresCredential, logger: Logger) throws {
        self.configuration = configuration
        self.resolvedConfiguration = resolved
        self.logger = logger
        self.pools = NIOLockedValueBox(try Self.makePool(resolved, expiresAt: credential.expiresAt, logger: logger))
    }

    private static func makePool(_ configuration: PostgresWireConfiguration, expiresAt: Date?, logger: Logger) throws -> Pool {
        let client = PostgresClient(configuration: try configuration.makeClientConfiguration(), backgroundLogger: logger)
        return Pool(client: client, runTask: Task.detached { await client.run() }, expiresAt: expiresAt)
    }

    deinit {
        pools.withLockedValue { $0.runTask.cancel() }
    }

    public static func connect(
        configuration: PostgresWireConfiguration,
        logger: Logger = .init(label: "postgres.wire.client")
    ) async throws -> PostgresWireClient {
        // Phase 1: Eager validation with a direct (non-pooled) connection. Wrong credentials fail right
        // away instead of the pool retrying until timeout, and this is where the host is selected.
        let opened = try await openSelectedConnection(configuration: configuration, logger: logger)
        try? await opened.connection.close()

        // Phase 2: create the pool for the selected host.
        let resolved = opened.configuration
        let client = try PostgresWireClient(configuration: configuration, resolved: resolved, credential: opened.credential, logger: logger)
        let target = resolved.unixSocketPath ?? "\(resolved.host):\(resolved.port)"
        logger.info("Connected to \(target)/\(resolved.database ?? "postgres"), sslMode=\(resolved.sslMode.rawValue)")
        return client
    }

    /// Open a single, non-pooled connection with the same settings as the pool.
    ///
    /// See ``openSelectedConnection(configuration:id:logger:)`` for host selection and deadlines.
    public static func openConnection(
        configuration: PostgresWireConfiguration,
        id: Int = 0,
        logger: Logger
    ) async throws -> PostgresConnection {
        try await openSelectedConnection(configuration: configuration, id: id, logger: logger).connection
    }

    public func close() {
        pools.withLockedValue { $0.runTask.cancel() }
        rotation.withLockedValue { $0?.cancel() }
    }

    /// The current pool, replaced first when its credential is about to expire.
    private func pool() async throws -> PostgresClient {
        let current = pools.withLockedValue { $0 }
        guard let expiresAt = current.expiresAt, configuration.passwordProvider != nil,
              expiresAt.timeIntervalSinceNow < Self.rotationMargin else {
            return current.client
        }
        let task = rotation.withLockedValue { box -> Task<Void, any Error> in
            if let running = box { return running }
            let started = Task { try await self.rotatePool() }
            box = started
            return started
        }
        do {
            try await task.value
        } catch {
            rotation.withLockedValue { $0 = nil }
            // The old credential may still be valid for a little while; only fail once it is not.
            if expiresAt.timeIntervalSinceNow > 0 { return current.client }
            throw error
        }
        rotation.withLockedValue { $0 = nil }
        return pools.withLockedValue { $0.client }
    }

    private func rotatePool() async throws {
        guard let provider = configuration.passwordProvider else { return }
        let credential = try await provider()
        var fresh = resolvedConfiguration
        fresh.password = credential.password
        let replacement = try Self.makePool(fresh, expiresAt: credential.expiresAt, logger: logger)
        let retired = pools.withLockedValue { box -> Pool in
            let old = box
            box = replacement
            return old
        }
        logger.debug("Replaced the connection pool before its credential expires")
        Task.detached {
            try? await Task.sleep(for: Self.retiredPoolGrace)
            retired.runTask.cancel()
        }
    }

    public func withConnection<T>(
        _ operation: (WireConnection) async throws -> T
    ) async throws -> T {
        try await pool().withConnection { connection in
            try await operation(WireConnection(connection))
        }
    }

    public var activity: PostgresActivityMonitor {
        PostgresActivityMonitor(client: self)
    }

    public func query(_ query: WireQuery, logger: Logger? = nil) async throws -> WireRowSequence {
        try await pool().query(query.asPostgresQuery(), logger: logger ?? self.logger)
    }

    public func query(
        _ query: WireQuery,
        options: PostgresExecutionOptions?,
        logger: Logger? = nil
    ) async throws -> WireRowSequence {
        // Advisory surface for now; forwards to existing path.
        _ = options
        return try await self.query(query, logger: logger)
    }

    /// Ask the server to cancel whatever the backend with `pid` is running (`pg_cancel_backend`).
    ///
    /// Runs on a pooled connection, so it works while the target connection is busy.
    /// Returns `false` when the server did not signal the backend (for example, it no longer exists).
    @discardableResult
    public func cancelBackend(pid: Int32) async throws -> Bool {
        var binds = PostgresBindings()
        binds.append(pid)
        let rows = try await pool().query(PostgresQuery(unsafeSQL: "SELECT pg_cancel_backend($1)", binds: binds), logger: logger)
        for try await signalled in rows.decode(Bool.self) {
            return signalled
        }
        return false
    }
}

// MARK: - Deadline

extension PostgresWireClient {
    /// Run `operation` against a hard deadline and return as soon as either finishes.
    ///
    /// Unlike a task group, this does not wait for `operation` to observe cancellation: when the
    /// deadline wins, the error is thrown immediately and a late result is handed to `onLateSuccess`.
    static func withDeadline<T: Sendable>(
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T,
        onLateSuccess: @escaping @Sendable (T) async -> Void
    ) async throws -> T {
        let pending = NIOLockedValueBox<CheckedContinuation<T, any Error>?>(nil)
        @Sendable func resume(_ result: Result<T, any Error>) -> Bool {
            guard let continuation = pending.withLockedValue({ box -> CheckedContinuation<T, any Error>? in
                defer { box = nil }
                return box
            }) else { return false }
            continuation.resume(with: result)
            return true
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending.withLockedValue { $0 = continuation }
            let work = Task {
                do {
                    let value = try await operation()
                    if !resume(.success(value)) { await onLateSuccess(value) }
                } catch {
                    _ = resume(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 1)) * 1_000_000_000)
                if resume(.failure(IOError(errnoCode: ETIMEDOUT, reason: "connect timeout"))) {
                    work.cancel()
                }
            }
        }
    }
}
