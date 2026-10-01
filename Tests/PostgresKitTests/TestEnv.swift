import Foundation
import Logging
import PostgresKit
import PostgresKitTesting

/// The server for the XCTest suites: `POSTGRES_TEST_URL` (see TESTING.md), with the suite's sample
/// data in a database of its own (``SampleDatabase``). Nothing is read from `.env` files.
enum TestEnv {
    static var server: TestServer? { TestServer.url() }

    static var isConfigured: Bool { server != nil }

    static var host: String { server?.configuration.host ?? "127.0.0.1" }
    static var port: Int { server?.configuration.port ?? 5432 }
    static var username: String { server?.configuration.username ?? "postgres" }
    static var password: String? { server?.configuration.password }
    /// The run's sample database once ``SampleDatabase/prepare(logger:)`` has made it; the URL's
    /// database before that.
    static var database: String { SampleDatabase.name ?? server?.configuration.database ?? "postgres" }
    /// For tests that build `PostgresConfiguration(useTLS:)`: true when the URL requires TLS.
    static var useTLS: Bool {
        guard let mode = server?.configuration.sslMode else { return false }
        return mode == .require || mode == .verifyCA || mode == .verifyFull
    }

    /// The URL's configuration (TLS settings included) on the sample database, with overrides for
    /// the settings under test.
    static func configuration(
        database: String? = nil,
        username: String? = nil,
        password: String? = nil,
        applicationName: String? = "postgres-wire-tests",
        pool: PostgresPoolConfiguration = .init(),
        statementTimeout: Duration? = nil
    ) -> PostgresConfiguration {
        var configuration = server?.configuration
            ?? PostgresConfiguration(host: host, port: port, username: self.username, password: self.password)
        configuration.database = database ?? self.database
        if let username { configuration.username = username }
        if let password { configuration.password = password }
        configuration.applicationName = applicationName
        configuration.pool = pool
        configuration.statementTimeout = statementTimeout
        return configuration
    }
}
