import Foundation
import Logging
import PostgresNIO

/// A single connection plus the configuration it was actually opened with.
public struct PostgresOpenedConnection: Sendable {
    public let connection: PostgresConnection
    /// Bound to the selected host, with the resolved `sslmode` and password.
    public let configuration: PostgresWireConfiguration
    public let credential: PostgresCredential
}

extension PostgresWireClient {

    /// Open a single, non-pooled connection, choosing among ``PostgresWireConfiguration/host`` and
    /// ``PostgresWireConfiguration/additionalHosts`` like libpq does.
    ///
    /// - The password comes from ``PostgresWireConfiguration/passwordProvider`` when set.
    /// - Each host is tried in order (shuffled with `loadBalanceHosts`) and checked against
    ///   ``PostgresWireConfiguration/targetSessionAttributes``; `prefer-standby` makes a second pass that
    ///   accepts any server.
    /// - `sslmode=allow` first tries without TLS and retries with TLS if the server rejects that.
    /// - Hostnames are resolved first so typos fail immediately, and each connect is raced against a
    ///   hard deadline of `connectTimeout` seconds (NIO's own timeout is unreliable with Network.framework).
    public static func openSelectedConnection(
        configuration: PostgresWireConfiguration,
        id: Int = 0,
        logger: Logger
    ) async throws -> PostgresOpenedConnection {
        let credential = try await configuration.passwordProvider?() ?? PostgresCredential(password: configuration.password)
        let hosts = configuration.candidateHosts
        let attributes = configuration.targetSessionAttributes
        var attempts: [(host: PostgresHost, reason: String)] = []
        var lastError: (any Error)?

        for standbyPass in attributes == .preferStandby ? [true, false] : [false] {
            for host in hosts {
                let candidate = configuration.resolved(host: host, sslMode: configuration.sslMode, password: credential.password)
                do {
                    let (connection, effective) = try await openWithSSLFallback(candidate, id: id, logger: logger)
                    if try await matches(connection, attributes: attributes, standbyPass: standbyPass, logger: logger) {
                        return PostgresOpenedConnection(connection: connection, configuration: effective, credential: credential)
                    }
                    try? await connection.close()
                    attempts.append((host, "does not satisfy \(attributes.rawValue)"))
                } catch {
                    lastError = error
                    attempts.append((host, String(describing: error)))
                }
            }
        }
        // With a single host and no attribute check, surface the original error unchanged.
        if hosts.count == 1, attributes == .any, let lastError { throw lastError }
        throw PostgresHostSelectionError(attributes: attributes, attempts: attempts)
    }

    /// Connects once, or for `sslmode=allow` twice (plain, then TLS if the server insists on encryption).
    static func openWithSSLFallback(
        _ configuration: PostgresWireConfiguration,
        id: Int,
        logger: Logger
    ) async throws -> (PostgresConnection, PostgresWireConfiguration) {
        guard configuration.sslMode == .allow, configuration.unixSocketPath == nil else {
            return (try await connectOnce(configuration, id: id, logger: logger), configuration)
        }
        var plain = configuration
        plain.sslMode = .disable
        do {
            return (try await connectOnce(plain, id: id, logger: logger), plain)
        } catch let error as PSQLError where Self.rejectsUnencrypted(error) {
            var encrypted = configuration
            encrypted.sslMode = .require
            return (try await connectOnce(encrypted, id: id, logger: logger), encrypted)
        }
    }

    /// `pg_hba.conf` has no entry for unencrypted connections ("no encryption" / "SSL off").
    static func rejectsUnencrypted(_ error: PSQLError) -> Bool {
        guard error.serverInfo?[.sqlState] == "28000", let message = error.serverInfo?[.message]?.lowercased() else { return false }
        return message.contains("no encryption") || message.contains("ssl off")
    }

    private static func connectOnce(_ configuration: PostgresWireConfiguration, id: Int, logger: Logger) async throws -> PostgresConnection {
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

    private static func matches(
        _ connection: PostgresConnection,
        attributes: PostgresTargetSessionAttributes,
        standbyPass: Bool,
        logger: Logger
    ) async throws -> Bool {
        func flag(_ sql: PostgresQuery) async throws -> String {
            for try await value in try await connection.query(sql, logger: logger).decode(String.self) { return value }
            return ""
        }
        switch attributes {
        case .any:
            return true
        case .readWrite:
            return try await flag("SHOW transaction_read_only") == "off"
        case .readOnly:
            return try await flag("SHOW transaction_read_only") == "on"
        case .primary:
            return try await flag("SELECT pg_is_in_recovery()::text") == "false"
        case .standby:
            return try await flag("SELECT pg_is_in_recovery()::text") == "true"
        case .preferStandby:
            return standbyPass ? try await flag("SELECT pg_is_in_recovery()::text") == "true" : true
        }
    }
}
