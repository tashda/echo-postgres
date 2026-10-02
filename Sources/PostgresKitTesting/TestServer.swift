import Foundation
import PostgresKit
import Testing

/// A PostgreSQL server for tests, from one URL variable (the drivers' test-server convention):
///
/// | Variable | Server |
/// |---|---|
/// | `POSTGRES_TEST_URL` | a plain server |
/// | `POSTGRES_TEST_TLS_URL` | a server that requires TLS; the URL carries `sslmode` and the CA |
/// | `POSTGRES_TEST_KERBEROS_URL` | Kerberos logins (`authentication=kerberos`, `krb5Config`) |
/// | `POSTGRES_TEST_STANDBY_URL` | the standby of a primary/standby pair (the primary is `POSTGRES_TEST_URL`) |
/// | `POSTGRES_TEST_PROXY_URL`, `POSTGRES_TEST_PROXY_CONTROL` | the server through a Toxiproxy, and its HTTP API |
///
/// A test whose variable is missing is skipped, and the skip names the variable; with
/// `POSTGRES_TEST_REQUIRED=1` it fails instead. See TESTING.md.
public struct TestServer: Sendable {
    /// The variable the server came from.
    public let variable: String
    /// The URL as given.
    public let url: String
    /// Ready to connect: host, port, the URL's database, user, password and TLS settings.
    public let configuration: PostgresConfiguration
    /// `authentication=kerberos`: the login uses the user's ticket, not a password.
    public let usesKerberos: Bool
    /// `krb5Config`: the Kerberos settings file for this realm.
    public let kerberosConfigPath: String?
    /// The URL's password. For Kerberos it is not sent to the server; a test can use it to get a
    /// ticket when the user has none.
    public let password: String?
    /// For Kerberos: the URL's user, the principal the ticket must be for (`alice@LAB.TEST`). The
    /// database user is its name without the realm (`alice`), as `include_realm=0` maps it.
    public let kerberosPrincipal: String?

    public static let urlVariable = "POSTGRES_TEST_URL"
    public static let requiredVariable = "POSTGRES_TEST_REQUIRED"

    /// The server named by `variable`, or nil when it is not set (or empty).
    public static func url(_ variable: String = urlVariable, environment: [String: String] = ProcessInfo.processInfo.environment) -> TestServer? {
        guard let text = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        do {
            return try parse(text, variable: variable)
        } catch {
            // A malformed URL is a setup mistake: say so instead of skipping quietly.
            preconditionFailure("\(variable): \(error)")
        }
    }

    /// Whether a missing variable fails the test instead of skipping it.
    public static func isRequired(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[requiredVariable] == "1"
    }

    /// The message a missing variable gives.
    public static func missingMessage(_ variable: String) -> String {
        "Set \(variable) to run this test (see TESTING.md)."
    }

    /// The server of the enclosing `.testServer` trait.
    @TaskLocal public static var current: TestServer?
}

// MARK: - Parsing

/// Why a test URL could not be read.
public struct TestServerURLError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(description: String) { self.description = description }
}

extension TestServer {
    /// Reads `postgres://user:password@host:port/database?query` (or `postgresql://`). User and
    /// password are percent-encoded. Query keys are libpq's (`sslmode`, `sslrootcert`, `sslcert`,
    /// `sslkey`, `sslpassword`, `connect_timeout`, `application_name`, `krbsrvname`,
    /// `target_session_attrs`, `load_balance_hosts`) plus `authentication=kerberos`,
    /// `serviceHost` and `krb5Config` for Kerberos.
    public static func parse(_ text: String, variable: String = urlVariable) throws -> TestServer {
        guard let schemeEnd = text.range(of: "://") else { throw TestServerURLError(description: "not a URL: expected postgres://…") }
        let scheme = text[..<schemeEnd.lowerBound].lowercased()
        guard scheme == "postgres" || scheme == "postgresql" else {
            throw TestServerURLError(description: "the scheme is \(scheme), expected postgres")
        }
        let rest = text[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        var remainder = rest[authorityEnd...]

        // User info ends at the last "@" (an unencoded "@" in a password still parses).
        var user: String?, password: String?
        var hostPort = authority
        if let at = authority.lastIndex(of: "@") {
            let userInfo = authority[..<at]
            hostPort = authority[authority.index(after: at)...]
            if let colon = userInfo.firstIndex(of: ":") {
                user = try decode(userInfo[..<colon], "user")
                password = try decode(userInfo[userInfo.index(after: colon)...], "password")
            } else {
                user = try decode(userInfo, "user")
            }
        }

        var host = String(hostPort), port = 5432
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { throw TestServerURLError(description: "unclosed [ in the host") }
            host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let afterHost = hostPort[hostPort.index(after: close)...]
            if afterHost.hasPrefix(":") { port = try portNumber(afterHost.dropFirst()) }
        } else if let colon = hostPort.lastIndex(of: ":") {
            host = String(hostPort[..<colon])
            port = try portNumber(hostPort[hostPort.index(after: colon)...])
        }
        guard !host.isEmpty else { throw TestServerURLError(description: "no host") }

        var database = "postgres"
        if remainder.hasPrefix("/") {
            remainder = remainder.dropFirst()
            let pathEnd = remainder.firstIndex(of: "?") ?? remainder.endIndex
            let path = try decode(remainder[..<pathEnd], "database")
            if !path.isEmpty { database = path }
            remainder = remainder[pathEnd...]
        }
        var query: [String: String] = [:]
        if remainder.hasPrefix("?") {
            for pair in remainder.dropFirst().split(separator: "&", omittingEmptySubsequences: true) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = try decode(parts[0], "query key")
                query[key] = parts.count > 1 ? try decode(parts[1], key) : ""
            }
        }

        let usesKerberos = query["authentication"]?.lowercased() == "kerberos"
        guard let user, !user.isEmpty else { throw TestServerURLError(description: "no user") }
        let databaseUser = usesKerberos ? String(user.split(separator: "@", maxSplits: 1).first ?? Substring(user)) : user
        var configuration = PostgresConfiguration(
            host: host, port: port, database: database, username: databaseUser,
            password: usesKerberos ? nil : password,
            sslMode: try sslMode(query["sslmode"] ?? "prefer"),
            sslRootCertPath: query["sslrootcert"], sslCertPath: query["sslcert"], sslKeyPath: query["sslkey"],
            applicationName: query["application_name"] ?? "echo-postgres tests",
            connectTimeout: query["connect_timeout"].flatMap(Int.init) ?? 10,
            targetSessionAttributes: try query["target_session_attrs"].map(targetSessionAttributes) ?? .any,
            loadBalanceHosts: query["load_balance_hosts"] == "random"
        )
        configuration.sslKeyPassword = query["sslpassword"]
        if let service = query["krbsrvname"], !service.isEmpty { configuration.kerberosServiceName = service }
        if let serviceHost = query["serviceHost"], !serviceHost.isEmpty { configuration.kerberosServiceHost = serviceHost }
        return TestServer(variable: variable, url: text, configuration: configuration, usesKerberos: usesKerberos,
                          kerberosConfigPath: query["krb5Config"], password: password,
                          kerberosPrincipal: usesKerberos ? user : nil)
    }

    private static func decode(_ text: Substring, _ what: String) throws -> String {
        guard let decoded = String(text).removingPercentEncoding else {
            throw TestServerURLError(description: "the \(what) is not percent-encoded correctly")
        }
        return decoded
    }

    private static func portNumber(_ text: Substring) throws -> Int {
        guard let port = Int(text), (1...65535).contains(port) else { throw TestServerURLError(description: "the port \(text) is not a port number") }
        return port
    }

    private static func sslMode(_ text: String) throws -> PostgresSSLMode {
        switch text.lowercased() {
        case "disable": .disable
        case "allow": .allow
        case "prefer": .prefer
        case "require": .require
        case "verify-ca": .verifyCA
        case "verify-full": .verifyFull
        default: throw TestServerURLError(description: "sslmode=\(text) is not a libpq sslmode")
        }
    }

    private static func targetSessionAttributes(_ text: String) throws -> PostgresTargetSessionAttributes {
        guard let value = PostgresTargetSessionAttributes(rawValue: text) else {
            throw TestServerURLError(description: "target_session_attrs=\(text) is not a libpq value")
        }
        return value
    }
}

// MARK: - The trait

/// `@Suite(.testServer)` / `@Test(.testServer("POSTGRES_TEST_TLS_URL"))`: runs the test with
/// ``TestServer/current`` set from the variable; skips it when the variable is missing (the skip
/// names the variable), or fails it when `POSTGRES_TEST_REQUIRED=1`.
public struct TestServerTrait: SuiteTrait, TestTrait, TestScoping {
    public let variable: String

    public var isRecursive: Bool { true }

    public func prepare(for test: Test) async throws {
        guard TestServer.url(variable) == nil, !TestServer.isRequired() else { return }
        try await ConditionTrait.enabled(if: false, Comment(rawValue: TestServer.missingMessage(variable))).prepare(for: test)
    }

    public func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard let server = TestServer.url(variable) else {
            Issue.record(Comment(rawValue: "\(variable) is not set and \(TestServer.requiredVariable)=1. \(TestServer.missingMessage(variable))"))
            return
        }
        try await TestServer.$current.withValue(server) { try await function() }
    }
}

extension Trait where Self == TestServerTrait {
    /// A server from `POSTGRES_TEST_URL`.
    public static var testServer: Self { TestServerTrait(variable: TestServer.urlVariable) }
    /// A server from another variable, such as `POSTGRES_TEST_TLS_URL`.
    public static func testServer(_ variable: String) -> Self { TestServerTrait(variable: variable) }
}
