import Foundation
import Logging

/// Pool settings for ``PostgresClient``. The defaults match PostgresNIO's own defaults.
///
/// A pool hands out *any* free connection per call and closes idle ones, so it must not be used for
/// interactive sessions where the user runs `BEGIN`, `SET`, temp tables and so on across several
/// calls. Use ``PostgresSessionConnection`` for that.
public struct PostgresPoolConfiguration: Sendable, Equatable {
    public var minimum: Int
    public var maximum: Int
    public var idleTimeoutSeconds: Int
    /// Interval of the keep-alive query on idle pooled connections, `nil` to disable.
    public var keepAliveSeconds: Int?

    public init(minimum: Int = 0, maximum: Int = 20, idleTimeoutSeconds: Int = 60, keepAliveSeconds: Int? = 30) {
        self.minimum = minimum
        self.maximum = maximum
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.keepAliveSeconds = keepAliveSeconds
    }
}

public struct PostgresConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var database: String
    public var username: String
    public var password: String?
    public var sslMode: PostgresSSLMode
    /// Path to a PEM-encoded root CA certificate file for verify-ca / verify-full modes.
    public var sslRootCertPath: String?
    /// Path to a PEM-encoded client certificate file for mTLS.
    public var sslCertPath: String?
    /// Path to a PEM-encoded client private key file for mTLS.
    public var sslKeyPath: String?
    /// The password protecting ``sslKeyPath`` (libpq `sslpassword`), if the key is encrypted.
    public var sslKeyPassword: String?
    /// Kerberos service name (libpq `krbsrvname`); `nil` refuses Kerberos. See ``PostgresKerberos``.
    public var kerberosServiceName: String? = "postgres"
    /// Reported to the server as `application_name` (visible in `pg_stat_activity`).
    public var applicationName: String?
    public var pool: PostgresPoolConfiguration
    /// TCP connect timeout in seconds. Defaults to 10.
    public var connectTimeout: Int
    /// Connect through a Unix domain socket instead of TCP (`host`, `port` and TLS are then ignored).
    public var unixSocketPath: String?
    /// Server-side `statement_timeout` for every connection, `nil` for the server default.
    public var statementTimeout: Duration?
    /// Server-side `lock_timeout` for every connection, `nil` for the server default.
    public var lockTimeout: Duration?
    /// Server-side `idle_in_transaction_session_timeout`, `nil` for the server default.
    public var idleInTransactionSessionTimeout: Duration?
    /// Extra run-time parameters sent at connection start (for example `search_path`).
    public var additionalStartupParameters: [String: String]
    /// Further servers to try after `host`/`port` (libpq multi-host).
    public var additionalHosts: [PostgresHost]
    /// Which server to accept among the hosts (libpq `target_session_attrs`).
    public var targetSessionAttributes: PostgresTargetSessionAttributes
    /// Try the hosts in random order (libpq `load_balance_hosts=random`).
    public var loadBalanceHosts: Bool
    /// Supplies the password per connection (short-lived tokens such as AWS RDS IAM); see
    /// ``PostgresAWSRDSAuthToken``. Overrides ``password``.
    public var passwordProvider: PostgresPasswordProvider?

    /// Whether TLS is enabled (any mode other than `disable`).
    public var useTLS: Bool { sslMode != .disable }

    public init(
        host: String,
        port: Int = 5432,
        database: String = "postgres",
        username: String,
        password: String?,
        sslMode: PostgresSSLMode = .disable,
        sslRootCertPath: String? = nil,
        sslCertPath: String? = nil,
        sslKeyPath: String? = nil,
        applicationName: String? = nil,
        pool: PostgresPoolConfiguration = .init(),
        connectTimeout: Int = 10,
        unixSocketPath: String? = nil,
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
        self.database = database
        self.username = username
        self.password = password
        self.sslMode = sslMode
        self.sslRootCertPath = sslRootCertPath
        self.sslCertPath = sslCertPath
        self.sslKeyPath = sslKeyPath
        self.applicationName = applicationName
        self.pool = pool
        self.connectTimeout = connectTimeout
        self.unixSocketPath = unixSocketPath
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
        database: String = "postgres",
        username: String,
        password: String?,
        useTLS: Bool,
        applicationName: String? = nil,
        pool: PostgresPoolConfiguration = .init(),
        connectTimeout: Int = 10
    ) {
        self.init(
            host: host,
            port: port,
            database: database,
            username: username,
            password: password,
            sslMode: useTLS ? .require : .disable,
            applicationName: applicationName,
            pool: pool,
            connectTimeout: connectTimeout
        )
    }
}

extension PostgresConfiguration {
    public func makeWireConfiguration() -> PostgresWireConfiguration {
        var configuration = PostgresWireConfiguration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            sslMode: sslMode,
            sslRootCertPath: sslRootCertPath,
            sslCertPath: sslCertPath,
            sslKeyPath: sslKeyPath,
            applicationName: applicationName,
            connectTimeout: connectTimeout,
            unixSocketPath: unixSocketPath,
            pool: PostgresWirePoolOptions(
                minimumConnections: pool.minimum,
                maximumConnections: pool.maximum,
                idleTimeout: .seconds(pool.idleTimeoutSeconds),
                keepAliveFrequency: pool.keepAliveSeconds.map { .seconds($0) }
            ),
            statementTimeout: statementTimeout,
            lockTimeout: lockTimeout,
            idleInTransactionSessionTimeout: idleInTransactionSessionTimeout,
            additionalStartupParameters: additionalStartupParameters,
            additionalHosts: additionalHosts,
            targetSessionAttributes: targetSessionAttributes,
            loadBalanceHosts: loadBalanceHosts,
            passwordProvider: passwordProvider
        )
        configuration.sslKeyPassword = sslKeyPassword
        configuration.kerberosServiceName = kerberosServiceName
        return configuration
    }
}
