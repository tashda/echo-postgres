import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import PostgresNIO

public final class PostgresWireClient: @unchecked Sendable {
    private let client: PostgresClient
    private let runTask: Task<Void, Never>
    let logger: Logger

    private init(client: PostgresClient, logger: Logger) {
        self.client = client
        self.logger = logger
        self.runTask = Task.detached { await client.run() }
    }

    deinit {
        runTask.cancel()
    }

    public static func connect(
        configuration: PostgresWireConfiguration,
        logger: Logger = .init(label: "postgres.wire.client")
    ) async throws -> PostgresWireClient {
        // Phase 1: Eager validation with a direct (non-pooled) connection.
        // This gives us immediate feedback: wrong credentials return an auth
        // error right away instead of the pool retrying until timeout.
        let probe = try await openConnection(configuration: configuration, logger: logger)
        try? await probe.close()

        // Phase 2: Probe succeeded — create the pool-based client for ongoing use.
        let client = PostgresClient(configuration: try configuration.makeClientConfiguration(), backgroundLogger: logger)
        let target = configuration.unixSocketPath ?? "\(configuration.host):\(configuration.port)"
        logger.info("Connected to \(target)/\(configuration.database ?? "postgres"), sslMode=\(configuration.sslMode.rawValue)")
        return PostgresWireClient(client: client, logger: logger)
    }

    /// Open a single, non-pooled connection with the same settings as the pool.
    ///
    /// The hostname is resolved first so typos fail immediately, and the connect is raced against a
    /// hard deadline of `connectTimeout` seconds: NIO's own connect timeout does not fire reliably on
    /// macOS (Network.framework). When the deadline wins this returns at once; a connection that
    /// completes later is closed in the background.
    public static func openConnection(
        configuration: PostgresWireConfiguration,
        id: Int = 0,
        logger: Logger
    ) async throws -> PostgresConnection {
        if configuration.unixSocketPath == nil {
            try await resolveHostname(configuration.host, port: configuration.port)
        }
        let connectionConfiguration = try configuration.makeConnectionConfiguration()
        return try await withDeadline(
            seconds: configuration.connectTimeout,
            operation: {
                try await PostgresConnection.connect(configuration: connectionConfiguration, id: id, logger: logger)
            },
            onLateSuccess: { connection in
                try? await connection.close()
            }
        )
    }

    public func close() {
        runTask.cancel()
    }

    public func withConnection<T>(
        _ operation: (WireConnection) async throws -> T
    ) async throws -> T {
        try await client.withConnection { connection in
            try await operation(WireConnection(connection))
        }
    }

    public var activity: PostgresActivityMonitor {
        PostgresActivityMonitor(client: self)
    }

    public func query(_ query: WireQuery, logger: Logger? = nil) async throws -> WireRowSequence {
        try await client.query(query.asPostgresQuery(), logger: logger ?? self.logger)
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
        let rows = try await client.query(PostgresQuery(unsafeSQL: "SELECT pg_cancel_backend($1)", binds: binds), logger: logger)
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
