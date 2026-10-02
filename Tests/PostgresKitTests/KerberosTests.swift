import Foundation
import PostgresKit
import PostgresKitTesting
import Testing

/// Kerberos (GSSAPI) logins: `POSTGRES_TEST_KERBEROS_URL`
/// (`postgres://alice%40REALM@host/db?authentication=kerberos&serviceHost=…&krb5Config=…`).
/// They sign in with the user's ticket: `kinit` the URL's user first, or put the password in the
/// URL and the suite gets a ticket into a cache of its own. Without either the suite is skipped.
/// The process's Kerberos settings are shared, so the tests run one at a time.
@Suite(.testServer("POSTGRES_TEST_KERBEROS_URL"), .serialized,
       .enabled("Needs a Kerberos ticket for the URL's user: kinit it, or put its password in the URL") { KerberosSetup.ready() })
struct KerberosTests {
    private var server: TestServer {
        get throws { try #require(TestServer.current) }
    }

    private func signedIn(_ configuration: PostgresConfiguration) async throws -> (user: String?, gss: String?, principal: String?) {
        let client = try await PostgresClient.connect(configuration: configuration)
        defer { client.close() }
        let result = try await client.simpleQueryResult(
            "SELECT current_user::text, g.gss_authenticated::text, g.principal FROM pg_stat_gssapi g WHERE g.pid = pg_backend_pid()")
        let row = Array(try #require(result.rows.first))
        let formatter = PostgresCellFormatter()
        return (formatter.stringValue(for: row[0]), formatter.stringValue(for: row[1]), formatter.stringValue(for: row[2]))
    }

    private func kerberosError(_ error: any Error) -> PostgresKerberosError? {
        if case .kerberos(let kerberos)? = (error as? PostgresError)?.connectionProblem { return kerberos }
        return nil
    }

    @Test func signsInWithTheTicket() async throws {
        let server = try server
        let outcome = try await signedIn(server.configuration)
        #expect(outcome.gss == "true")
        #expect(outcome.principal?.lowercased() == server.kerberosPrincipal?.lowercased())
        #expect(outcome.user == server.configuration.username)
    }

    @Test func currentTicketNamesTheUser() throws {
        let server = try server
        guard case .valid(let principal, let expiresAt) = PostgresKerberos.currentTicket() else {
            Issue.record("no valid ticket: \(PostgresKerberos.currentTicket())")
            return
        }
        #expect(principal.lowercased() == server.kerberosPrincipal?.lowercased())
        #expect(PostgresKerberos.currentTicket().userName?.lowercased() == server.configuration.username.lowercased())
        if let expiresAt { #expect(expiresAt > Date()) }
    }

    @Test func anUnknownServiceNameSaysSo() async throws {
        var configuration = try server.configuration
        configuration.kerberosServiceName = "nosuchservice"
        do {
            _ = try await signedIn(configuration)
            Issue.record("the realm has no nosuchservice principal")
        } catch {
            #expect(kerberosError(error)?.kind == .unknownService, "\(error): \((error as? PostgresError)?.detail ?? "")")
        }
    }

    @Test func kerberosTurnedOffSaysTheServerAsksForIt() async throws {
        var configuration = try server.configuration
        configuration.kerberosServiceName = nil
        do {
            _ = try await signedIn(configuration)
            Issue.record("the server asks this user for Kerberos")
        } catch {
            #expect(error.localizedDescription.contains("Kerberos"), "\(error)")
        }
    }

    @Test func noTicketSaysToGetOne() async throws {
        let configuration = try server.configuration
        let cache = ProcessInfo.processInfo.environment["KRB5CCNAME"] ?? getenv("KRB5CCNAME").map { String(cString: $0) }
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("no-ticket-\(UUID().uuidString)").path
        setenv("KRB5CCNAME", "FILE:\(empty)", 1)
        defer { if let cache { setenv("KRB5CCNAME", cache, 1) } else { unsetenv("KRB5CCNAME") } }
        #expect(PostgresKerberos.currentTicket() == .none)
        do {
            _ = try await signedIn(configuration)
            Issue.record("there is no ticket in an empty cache")
        } catch {
            #expect(kerberosError(error)?.kind == .noTicket, "\(error)")
        }
    }
}

/// Points the process at the URL's Kerberos settings and makes sure it has a ticket for the user.
enum KerberosSetup {
    private static let cache = FileManager.default.temporaryDirectory.appendingPathComponent("echo-postgres-krb5cc-\(getpid())").path

    static func ready() -> Bool {
        guard let server = TestServer.url("POSTGRES_TEST_KERBEROS_URL") else { return TestServer.isRequired() }
        if let config = server.kerberosConfigPath { setenv("KRB5_CONFIG", config, 1) }
        if hasTicket(for: server) { return true }
        if let password = server.password, let principal = server.kerberosPrincipal,
           kinit(principal, password: password), hasTicket(for: server) { return true }
        return TestServer.isRequired()
    }

    private static func hasTicket(for server: TestServer) -> Bool {
        guard case .valid(let principal, _) = PostgresKerberos.currentTicket() else { return false }
        return principal.lowercased() == server.kerberosPrincipal?.lowercased()
    }

    /// `kinit` into a cache of this process's own, so the user's tickets are left alone.
    private static func kinit(_ principal: String, password: String) -> Bool {
        let heimdal = run(["kinit", "--version"], input: nil).output.lowercased().contains("heimdal")
        let arguments = heimdal ? ["kinit", "-c", "FILE:\(cache)", "--password-file=STDIN", principal]
                                : ["kinit", "-c", "FILE:\(cache)", principal]
        guard run(arguments, input: password + "\n").status == 0 else { return false }
        setenv("KRB5CCNAME", "FILE:\(cache)", 1)
        return true
    }

    private static func run(_ arguments: [String], input: String?) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let output = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = stdin
        do { try process.run() } catch { return (-1, "") }
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
