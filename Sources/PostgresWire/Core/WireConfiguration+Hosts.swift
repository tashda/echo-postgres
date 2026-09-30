import Foundation

/// One server endpoint.
public struct PostgresHost: Sendable, Equatable, Hashable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int = 5432) {
        self.host = host
        self.port = port
    }
}

/// Which server to accept when several hosts are configured (libpq `target_session_attrs`).
public enum PostgresTargetSessionAttributes: String, Sendable, CaseIterable {
    /// The first server that accepts the connection.
    case any
    /// A server whose sessions are read-write by default (`transaction_read_only = off`).
    case readWrite = "read-write"
    /// A server whose sessions are read-only by default.
    case readOnly = "read-only"
    /// A server that is not in recovery (a primary).
    case primary
    /// A server in recovery (a standby).
    case standby
    /// A standby if one is reachable, otherwise any server.
    case preferStandby = "prefer-standby"
}

/// A password plus when it stops being valid.
public struct PostgresCredential: Sendable, Equatable {
    public var password: String?
    /// When the password stops being accepted for *new* connections (existing ones stay open).
    public var expiresAt: Date?

    public init(password: String?, expiresAt: Date? = nil) {
        self.password = password
        self.expiresAt = expiresAt
    }
}

/// Produces the credential for new connections. Called once per connection attempt.
public typealias PostgresPasswordProvider = @Sendable () async throws -> PostgresCredential

/// No configured host accepted the connection with the requested attributes.
public struct PostgresHostSelectionError: Error, LocalizedError, Sendable {
    public let attributes: PostgresTargetSessionAttributes
    /// Why each host was skipped, in the order they were tried.
    public let attempts: [(host: PostgresHost, reason: String)]

    public var errorDescription: String? {
        let details = attempts.map { "\($0.host.host):\($0.host.port): \($0.reason)" }.joined(separator: "; ")
        return "No server matched target_session_attrs=\(attributes.rawValue). \(details)"
    }
}

extension PostgresWireConfiguration {
    /// `host`/`port` followed by ``additionalHosts``, shuffled when ``loadBalanceHosts`` is set.
    var candidateHosts: [PostgresHost] {
        let hosts = [PostgresHost(host: host, port: port)] + additionalHosts
        return loadBalanceHosts ? hosts.shuffled() : hosts
    }

    /// A copy bound to one host, with the password resolved and multi-host options cleared.
    func resolved(host selected: PostgresHost, sslMode mode: PostgresSSLMode, password resolvedPassword: String?) -> PostgresWireConfiguration {
        var copy = self
        copy.host = selected.host
        copy.port = selected.port
        copy.sslMode = mode
        copy.password = resolvedPassword
        copy.additionalHosts = []
        copy.targetSessionAttributes = .any
        copy.loadBalanceHosts = false
        return copy
    }
}
