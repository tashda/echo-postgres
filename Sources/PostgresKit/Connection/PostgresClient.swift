import Foundation
import Logging
import Metrics
import NIOConcurrencyHelpers
import PostgresWire
import PostgresNIO

/// Primary high-level client for PostgreSQL interaction.
///
/// Use this client to manage connections, execute queries, and perform database administration.
public final class PostgresClient: @unchecked Sendable {
    internal let wire: PostgresWireClient
    internal let logger: Logger
    private let registry = PreparedRegistry()
    private let notifierBox = NIOLockedValueBox<PostgresNotifier?>(nil)

    /// LISTEN/NOTIFY support, created on first use. It references this client weakly.
    internal var notifierActor: PostgresNotifier {
        notifierBox.withLockedValue { box in
            if let notifier = box { return notifier }
            let notifier = PostgresNotifier(client: self, logger: logger)
            box = notifier
            return notifier
        }
    }

    private init(wire: PostgresWireClient, logger: Logger) {
        self.wire = wire
        var logger = logger
        logger[metadataKey: "component"] = "PostgresClient"
        self.logger = logger
    }

    deinit { wire.close() }

    /// Establish a connection to the database.
    public static func connect(
        configuration: PostgresConfiguration,
        logger: Logger = .init(label: "postgres-kit")
    ) async throws -> PostgresClient {
        let result: Result<PostgresClient, PostgresError> = await PostgresClient.executeWithEnhancedError {
            let wire = try await PostgresWireClient.connect(configuration: configuration.makeWireConfiguration(), logger: logger)
            return PostgresClient(wire: wire, logger: logger)
        }
        switch result {
        case .success(let client):
            return client
        case .failure(let error):
            throw error
        }
    }

    /// Explicitly close all connections.
    public func close() { wire.close() }

    /// The server this client's pool is connected to now. With several configured hosts it can
    /// change after a failover; ``hostChanges()`` reports each change.
    public var currentHost: PostgresHost { wire.currentHost }

    /// Reports each time the pool fails over to another configured host.
    public func hostChanges() -> AsyncStream<PostgresHostChange> { wire.hostChanges() }

    /// Connects to every configured host and reports whether each is a primary or a standby (for a
    /// connection test with several servers). Errors are translated like ``connect(configuration:logger:)``'s.
    public static func probeHosts(
        configuration: PostgresConfiguration,
        logger: Logger = .init(label: "postgres-kit")
    ) async -> [PostgresHostProbe] {
        await PostgresWireClient.probeHosts(configuration: configuration.makeWireConfiguration(), logger: logger)
    }

    /// Borrow a single connection for multi-step operations (e.g., transactions).
    public func withConnection<T>(
        _ body: @Sendable (PostgresConnection) async throws -> T
    ) async throws -> T {
        do {
            return try await wire.withConnection { connection in
                let cache = await registry.statementCache(for: connection.connectionID)
                let serverCache = await registry.serverPreparedCache(for: connection.connectionID)
                return try await body(PostgresConnection(wireConnection: connection, logger: logger, cache: cache, serverCache: serverCache))
            }
        } catch {
            // Translate driver errors; errors thrown by `body` itself pass through unchanged.
            throw PostgresKit.PostgresError.fromDriver(error)
        }
    }

    /// Run `body` inside `BEGIN … COMMIT` on one leased connection.
    ///
    /// Commits when `body` returns and rolls back when it throws (including cancellation). Every
    /// statement inside `body` must use the `connection` it is given — the client itself is a pool.
    public func withTransaction<T>(
        isolation: PostgresIsolationLevel? = nil,
        readOnly: Bool = false,
        _ body: @Sendable (PostgresConnection) async throws -> T
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

    /// Ask the server to cancel what backend `pid` is running (`pg_cancel_backend`).
    ///
    /// - Returns: `false` when the server did not signal the backend (for example, it no longer exists).
    @discardableResult
    public func cancelBackend(pid: Int32) async throws -> Bool {
        do {
            return try await wire.cancelBackend(pid: pid)
        } catch {
            throw PostgresError.from(error)
        }
    }

    /// Internal helper to convert values to wire format.
    internal func toPGData(value: Any) throws -> PGData {
        if let encodable = value as? PostgresEncodable {
            var data = PGData(type: encodable.pgDataType)
            try encodable.encode(into: &data)
            return data
        } else {
            throw PostgresError.encodingError(type: type(of: value))
        }
    }

    /// Execute a DDL statement and return the number of affected rows.
    @discardableResult
    internal func executeDDL(_ sql: String) async throws -> Int {
        let rows = try await wire.query(WireQuery(sql: sql))
        var count = 0
        for try await _ in rows.decode((String?).self) {
            count += 1
        }
        return count
    }

    /// Quote an identifier to prevent SQL injection.
    /// Handles schema-qualified names like "app.users" → "app"."users".
    internal func quoteIdentifier(_ identifier: String) -> String {
        PostgresQuoting.quoteQualifiedIdentifier(identifier)
    }

    /// Quote a single identifier (no schema splitting).
    internal func quoteSimpleIdentifier(_ identifier: String) -> String {
        PostgresQuoting.quoteIdentifier(identifier)
    }

    /// Quote a literal string to prevent SQL injection.
    internal func quoteLiteral(_ literal: String) -> String {
        PostgresQuoting.quoteLiteral(literal)
    }
}

// MARK: - Internal Registry

/// Per-connection caches keyed by the pool's connection ID (unique for the pool's lifetime).
///
/// The pool does not report closed connections, so the registry keeps the most recently used
/// `capacity` connections and drops the oldest beyond that.
private actor PreparedRegistry {
    private let capacity = 64
    private var stmtCaches: [Int: StatementCache] = [:]
    private var serverCaches: [Int: PreparedServerCache] = [:]
    private var order: [Int] = []

    private func touch(_ id: Int) {
        if let index = order.firstIndex(of: id) { order.remove(at: index) }
        order.append(id)
        while order.count > capacity {
            let evicted = order.removeFirst()
            stmtCaches[evicted] = nil
            serverCaches[evicted] = nil
        }
    }

    func statementCache(for id: Int) -> StatementCache {
        touch(id)
        if let cache = stmtCaches[id] { return cache }
        let new = StatementCache(capacity: 256)
        stmtCaches[id] = new
        return new
    }

    func serverPreparedCache(for id: Int) -> PreparedServerCache {
        touch(id)
        if let cache = serverCaches[id] { return cache }
        let new = PreparedServerCache(capacity: 128)
        serverCaches[id] = new
        return new
    }
}
