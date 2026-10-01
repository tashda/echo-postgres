import Foundation
import NIOCore
import PostgresNIO

/// SSL mode matching libpq's `sslmode` parameter.
public enum PostgresSSLMode: String, Sendable, CaseIterable {
    /// No SSL/TLS encryption.
    case disable
    /// Try non-SSL first, then SSL if the server rejects the unencrypted connection.
    case allow
    /// Try SSL first, fall back to non-SSL if the server doesn't support it.
    case prefer
    /// Require SSL but don't verify the server certificate.
    case require
    /// Require SSL and verify that the server certificate is signed by a trusted CA.
    case verifyCA = "verify-ca"
    /// Require SSL, verify the CA, and verify that the server hostname matches the certificate.
    case verifyFull = "verify-full"
}

/// Connection pool behaviour for ``PostgresWireClient``.
///
/// The defaults match PostgresNIO's own defaults.
public struct PostgresWirePoolOptions: Sendable, Equatable {
    /// Connections kept open even without demand.
    public var minimumConnections: Int
    /// Upper bound of simultaneously open connections.
    public var maximumConnections: Int
    /// How long a connection above ``minimumConnections`` may stay idle before it is closed.
    ///
    /// A pooled connection is never safe for `BEGIN … COMMIT` spread over several leases:
    /// use `PostgresSessionConnection` for interactive sessions.
    public var idleTimeout: Duration
    /// Interval of the keep-alive query on idle connections, `nil` to disable.
    public var keepAliveFrequency: Duration?

    public init(
        minimumConnections: Int = 0,
        maximumConnections: Int = 20,
        idleTimeout: Duration = .seconds(60),
        keepAliveFrequency: Duration? = .seconds(30)
    ) {
        self.minimumConnections = minimumConnections
        self.maximumConnections = maximumConnections
        self.idleTimeout = idleTimeout
        self.keepAliveFrequency = keepAliveFrequency
    }
}

public struct PostgresWireConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var database: String?
    public var sslMode: PostgresSSLMode
    /// Path to a PEM-encoded root CA certificate file for verify-ca / verify-full modes.
    public var sslRootCertPath: String?
    /// Path to a PEM-encoded client certificate file for mTLS, or a PKCS#12 file (`.p12`/`.pfx`)
    /// holding the certificate and its key.
    public var sslCertPath: String?
    /// Path to a PEM- or DER-encoded client private key file for mTLS (unused with a PKCS#12 file).
    public var sslKeyPath: String?
    /// The password protecting ``sslKeyPath`` or the PKCS#12 file (libpq `sslpassword`).
    public var sslKeyPassword: String?
    /// Kerberos service name (libpq `krbsrvname`): when the server asks for Kerberos (GSSAPI or
    /// SSPI), the user's ticket is used for `<service>@<host>`. `nil` refuses Kerberos.
    public var kerberosServiceName: String? = "postgres"
    /// The host name in the server's Kerberos principal (`<service>@<this>`), when it differs from
    /// ``host`` (connecting by IP address or through an alias). `nil` uses ``host``, as libpq does.
    public var kerberosServiceHost: String?
    /// Reported to the server as `application_name` (visible in `pg_stat_activity`).
    public var applicationName: String?
    /// TCP connect timeout in seconds. Defaults to 10.
    public var connectTimeout: Int
    /// Connect through a Unix domain socket instead of TCP. `host`, `port` and TLS are ignored when set.
    public var unixSocketPath: String?
    /// Pool behaviour of ``PostgresWireClient``.
    public var pool: PostgresWirePoolOptions
    /// Server-side `statement_timeout` for every connection, `nil` for the server default.
    public var statementTimeout: Duration?
    /// Server-side `lock_timeout` for every connection, `nil` for the server default.
    public var lockTimeout: Duration?
    /// Server-side `idle_in_transaction_session_timeout`, `nil` for the server default.
    public var idleInTransactionSessionTimeout: Duration?
    /// Extra run-time parameters sent in the startup packet (for example `search_path`).
    public var additionalStartupParameters: [String: String]
    /// Further servers to try after `host`/`port`, like libpq's multi-host connection strings.
    public var additionalHosts: [PostgresHost]
    /// Which kind of server to accept among ``host`` and ``additionalHosts`` (libpq `target_session_attrs`).
    public var targetSessionAttributes: PostgresTargetSessionAttributes
    /// Try the hosts in random order (libpq `load_balance_hosts=random`).
    public var loadBalanceHosts: Bool
    /// Supplies the password for each new connection instead of ``password`` — for short-lived tokens
    /// such as AWS RDS IAM authentication. When the credential expires, the pool is replaced with one
    /// that uses a fresh credential before the old one runs out.
    public var passwordProvider: PostgresPasswordProvider?

    /// Whether TLS is enabled (any mode other than `disable`).
    public var useTLS: Bool { sslMode != .disable }

    public init(
        host: String,
        port: Int = 5432,
        username: String,
        password: String?,
        database: String? = nil,
        sslMode: PostgresSSLMode = .disable,
        sslRootCertPath: String? = nil,
        sslCertPath: String? = nil,
        sslKeyPath: String? = nil,
        applicationName: String? = nil,
        connectTimeout: Int = 10,
        unixSocketPath: String? = nil,
        pool: PostgresWirePoolOptions = .init(),
        statementTimeout: Duration? = nil,
        lockTimeout: Duration? = nil,
        idleInTransactionSessionTimeout: Duration? = nil,
        additionalStartupParameters: [String: String] = [:],
        additionalHosts: [PostgresHost] = [],
        targetSessionAttributes: PostgresTargetSessionAttributes = .any,
        loadBalanceHosts: Bool = false,
        passwordProvider: PostgresPasswordProvider? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.sslMode = sslMode
        self.sslRootCertPath = sslRootCertPath
        self.sslCertPath = sslCertPath
        self.sslKeyPath = sslKeyPath
        self.applicationName = applicationName
        self.connectTimeout = connectTimeout
        self.unixSocketPath = unixSocketPath
        self.pool = pool
        self.statementTimeout = statementTimeout
        self.lockTimeout = lockTimeout
        self.idleInTransactionSessionTimeout = idleInTransactionSessionTimeout
        self.additionalStartupParameters = additionalStartupParameters
        self.additionalHosts = additionalHosts
        self.targetSessionAttributes = targetSessionAttributes
        self.loadBalanceHosts = loadBalanceHosts
        self.passwordProvider = passwordProvider
    }

    /// Backward-compatible initializer using a simple `useTLS` boolean.
    public init(
        host: String,
        port: Int = 5432,
        username: String,
        password: String?,
        database: String? = nil,
        useTLS: Bool,
        applicationName: String? = nil,
        connectTimeout: Int = 10
    ) {
        self.init(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            sslMode: useTLS ? .require : .disable,
            applicationName: applicationName,
            connectTimeout: connectTimeout
        )
    }

    /// Run-time parameters sent in the startup packet of every connection.
    public var startupParameters: [(String, String)] {
        var parameters: [(String, String)] = []
        if let applicationName, !applicationName.isEmpty {
            parameters.append(("application_name", applicationName))
        }
        if let statementTimeout {
            parameters.append(("statement_timeout", String(statementTimeout.postgresMilliseconds)))
        }
        if let lockTimeout {
            parameters.append(("lock_timeout", String(lockTimeout.postgresMilliseconds)))
        }
        if let idleInTransactionSessionTimeout {
            parameters.append(("idle_in_transaction_session_timeout", String(idleInTransactionSessionTimeout.postgresMilliseconds)))
        }
        for key in additionalStartupParameters.keys.sorted() {
            if let value = additionalStartupParameters[key] {
                parameters.append((key, value))
            }
        }
        return parameters
    }

    /// Configuration for a single, non-pooled `PostgresConnection` with the same endpoint, TLS,
    /// credentials and startup parameters as the pool.
    public func makeConnectionConfiguration() throws -> PostgresConnection.Configuration {
        var configuration: PostgresConnection.Configuration
        if let unixSocketPath {
            configuration = PostgresConnection.Configuration(
                unixSocketPath: unixSocketPath,
                username: username,
                password: password,
                database: database ?? "postgres"
            )
        } else {
            configuration = PostgresConnection.Configuration(
                host: host,
                port: port,
                username: username,
                password: password,
                database: database ?? "postgres",
                tls: try PostgresWireClient.makeConnectionTLS(
                    sslMode: sslMode,
                    sslRootCertPath: sslRootCertPath,
                    sslCertPath: sslCertPath,
                    sslKeyPath: sslKeyPath,
                    sslKeyPassword: sslKeyPassword
                )
            )
        }
        configuration.options.connectTimeout = .seconds(Int64(connectTimeout))
        configuration.options.additionalStartupParameters = startupParameters
        if unixSocketPath == nil, let kerberosServiceName {
            configuration.options.gssAuthenticatorFactory = PostgresKerberos.authenticatorFactory(serviceName: kerberosServiceName, host: kerberosServiceHost ?? host)
        }
        return configuration
    }

    /// Configuration for the PostgresNIO connection pool.
    public func makeClientConfiguration() throws -> PostgresClient.Configuration {
        var configuration: PostgresClient.Configuration
        if let unixSocketPath {
            configuration = PostgresClient.Configuration(
                unixSocketPath: unixSocketPath,
                username: username,
                password: password,
                database: database ?? "postgres"
            )
        } else {
            configuration = PostgresClient.Configuration(
                host: host,
                port: port,
                username: username,
                password: password,
                database: database ?? "postgres",
                tls: try PostgresWireClient.makePoolTLS(
                    sslMode: sslMode,
                    sslRootCertPath: sslRootCertPath,
                    sslCertPath: sslCertPath,
                    sslKeyPath: sslKeyPath,
                    sslKeyPassword: sslKeyPassword
                )
            )
        }
        configuration.options.connectTimeout = .seconds(Int64(connectTimeout))
        configuration.options.additionalStartupParameters = startupParameters
        if unixSocketPath == nil, let kerberosServiceName {
            configuration.options.gssAuthenticatorFactory = PostgresKerberos.authenticatorFactory(serviceName: kerberosServiceName, host: kerberosServiceHost ?? host)
        }
        configuration.options.minimumConnections = max(0, pool.minimumConnections)
        configuration.options.maximumConnections = max(1, max(pool.minimumConnections, pool.maximumConnections))
        configuration.options.connectionIdleTimeout = pool.idleTimeout
        // A server that can't be reached for connectTimeout counts as down, so the client can move
        // to another host (or say so) instead of waiting PostgresNIO's 60 s.
        configuration.options.circuitBreakerTripAfter = .seconds(Int64(max(connectTimeout, 1)))
        configuration.options.keepAliveBehavior = pool.keepAliveFrequency.map { .init(frequency: $0) }
        return configuration
    }
}

extension Duration {
    /// Whole milliseconds, the unit Postgres uses for timeout parameters.
    var postgresMilliseconds: Int64 {
        let parts = components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }
}
