import Foundation
import Logging

/// A server-level connection that manages per-database clients.
///
/// PostgreSQL binds each connection to a single database — there is no `USE database`
/// command. `PostgresServerConnection` solves this by wrapping multiple
/// ``PostgresClient`` instances (one per database) behind a single API.
/// It reuses the original connection's host, port, TLS, and auth settings to create
/// new database-specific clients on demand, caching them for reuse.
///
/// ## Usage
///
/// Connect to a server, then request clients for any database:
///
/// ```swift
/// let server = try await PostgresServerConnection.connect(
///     configuration: config,
///     logger: logger
/// )
///
/// // The primary client is always available for server-wide operations.
/// let databases = try await server.primaryClient.listDatabases()
///
/// // Access a specific database — creates a new connection on first call,
/// // returns the cached client on subsequent calls.
/// let analyticsClient = try await server.client(for: "analytics")
/// let rows = try await analyticsClient.simpleQuery("SELECT count(*) FROM events")
///
/// // Requesting the primary database by name returns the same primaryClient.
/// let sameClient = try await server.client(for: server.connectedDatabase)
/// assert(sameClient === server.primaryClient)
///
/// // Clean up all connections when done.
/// await server.closeAll()
/// ```
///
/// ## Thread Safety
///
/// `PostgresServerConnection` is `Sendable`. The internal client cache is protected
/// by an actor, so ``client(for:)`` can be called safely from any task or actor context.
///
/// ## When to Use
///
/// Use `PostgresServerConnection` when your application needs to query across multiple
/// databases on the same server (e.g., a database browser, a multi-tenant system with
/// per-tenant databases, or a migration tool). If you only ever connect to a single
/// database, use ``PostgresClient`` directly.
public final class PostgresServerConnection: Sendable {

    /// The client for the initially connected database.
    public let primaryClient: PostgresClient

    /// The database name the primary client is connected to.
    ///
    /// Resolved at connect time via `SELECT current_database()`. This handles the case
    /// where ``PostgresConfiguration/database`` is empty and PostgreSQL defaults to the
    /// login username.
    public let connectedDatabase: String

    private let configuration: PostgresConfiguration
    private let logger: Logger
    private let clients: ClientCache

    private init(
        primaryClient: PostgresClient,
        connectedDatabase: String,
        configuration: PostgresConfiguration,
        logger: Logger
    ) {
        self.primaryClient = primaryClient
        self.connectedDatabase = connectedDatabase
        self.configuration = configuration
        self.logger = logger
        self.clients = ClientCache()
    }

    /// Connect to a PostgreSQL server.
    ///
    /// Creates the primary ``PostgresClient`` using the provided configuration
    /// and resolves the actual connected database name via `SELECT current_database()`.
    ///
    /// - Parameters:
    ///   - configuration: Connection settings (host, port, credentials, TLS, pool).
    ///   - logger: Logger for all clients created by this server connection.
    /// - Returns: A connected server connection ready to vend per-database clients.
    /// - Throws: ``PostgresError`` if the initial connection or database name query fails.
    public static func connect(
        configuration: PostgresConfiguration,
        logger: Logger = .init(label: "postgres-kit")
    ) async throws -> PostgresServerConnection {
        let client = try await PostgresClient.connect(
            configuration: configuration,
            logger: logger
        )
        let dbName = try await resolveCurrentDatabase(client: client)
        return PostgresServerConnection(
            primaryClient: client,
            connectedDatabase: dbName,
            configuration: configuration,
            logger: logger
        )
    }

    /// Returns a client connected to the specified database.
    ///
    /// - If `database` matches the primary (case-insensitive), returns ``primaryClient``.
    /// - Otherwise, returns a cached client or creates a new one on demand.
    /// - New clients reuse the same host, port, TLS, auth, and pool settings.
    ///
    /// - Parameter database: The PostgreSQL database name to connect to.
    /// - Returns: A ``PostgresClient`` connected to the requested database.
    /// - Throws: ``PostgresError`` if a new connection cannot be established.
    public func client(for database: String) async throws -> PostgresClient {
        if database.lowercased() == connectedDatabase.lowercased() {
            return primaryClient
        }
        var dbConfig = configuration
        dbConfig.database = database
        let logger = self.logger
        return try await clients.client(for: database) { [dbConfig] in
            try await PostgresClient.connect(configuration: dbConfig, logger: logger)
        }
    }

    /// Closes and forgets the cached client for `database`, so a server with many databases does not keep one
    /// connection open for each (PostgreSQL's default allows 100 clients). The primary client stays. A later
    /// ``client(for:)`` connects again.
    public func releaseClient(for database: String) async {
        guard database.lowercased() != connectedDatabase.lowercased() else { return }
        await clients.release(database)
    }

    /// Open a dedicated ``PostgresSessionConnection`` (not pooled) to `database` with this server's
    /// settings — for query tabs and anything else that needs transactions or session state.
    public func makeSession(
        database: String? = nil,
        keepAliveInterval: Duration? = .seconds(30)
    ) async throws -> PostgresSessionConnection {
        var sessionConfig = configuration
        sessionConfig.database = database ?? connectedDatabase
        return try await PostgresSessionConnection.connect(configuration: sessionConfig, keepAliveInterval: keepAliveInterval, logger: logger)
    }

    /// Close all connections (primary + all cached database clients).
    ///
    /// After calling this method, the server connection should not be reused.
    public func closeAll() async {
        primaryClient.close()
        await clients.closeAll()
    }

    private static func resolveCurrentDatabase(
        client: PostgresClient
    ) async throws -> String {
        let rows = try await client.simpleQuery("SELECT current_database()")
        for try await name in rows.decode(String.self) {
            return name
        }
        throw PostgresError(message: "Failed to resolve current database name")
    }
}

// MARK: - Client Cache

private actor ClientCache {
    private var cached: [String: PostgresClient] = [:]
    private var pending: [String: Task<PostgresClient, any Error>] = [:]
    private var isClosed = false

    /// The cached client, or the result of the connect already in progress for `database`, or a new
    /// connect — so concurrent first requests share one pool instead of each creating (and leaking) one.
    func client(
        for database: String,
        connect: @escaping @Sendable () async throws -> PostgresClient
    ) async throws -> PostgresClient {
        let key = database.lowercased()
        if let client = cached[key] { return client }
        if let task = pending[key] { return try await task.value }
        let task = Task { try await connect() }
        pending[key] = task
        do {
            let client = try await task.value
            pending[key] = nil
            if isClosed {
                client.close()
                throw PostgresError(message: "The server connection has been closed")
            }
            cached[key] = client
            return client
        } catch {
            pending[key] = nil
            throw error
        }
    }

    func release(_ database: String) {
        cached.removeValue(forKey: database.lowercased())?.close()
    }

    func closeAll() {
        isClosed = true
        for client in cached.values {
            client.close()
        }
        cached.removeAll()
    }
}
