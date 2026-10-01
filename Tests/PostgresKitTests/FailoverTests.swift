import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PostgresKit
import PostgresKitTesting
import Testing

/// The pool moves to another configured host when its server stops answering:
/// `POSTGRES_TEST_PROXY_URL` (the server through a Toxiproxy), `POSTGRES_TEST_PROXY_CONTROL` (its
/// HTTP API, to switch the proxy off and on) and `POSTGRES_TEST_URL` (the server directly, the
/// second host). TESTING.md has the `docker run` lines.
@Suite(.testServer("POSTGRES_TEST_PROXY_URL"), .serialized)
struct ProxyFailoverTests {
    private func setup() throws -> (proxied: PostgresConfiguration, direct: PostgresConfiguration, proxy: Toxiproxy) {
        let proxied = try #require(TestServer.current).configuration
        let direct = try #require(TestServer.url(TestServer.urlVariable), "\(TestServer.urlVariable) is the second host").configuration
        let control = try #require(ProcessInfo.processInfo.environment["POSTGRES_TEST_PROXY_CONTROL"], "POSTGRES_TEST_PROXY_CONTROL is not set")
        return (proxied, direct, Toxiproxy(control: control))
    }

    private func port(_ client: PostgresClient) async throws -> Int {
        let result = try await client.simpleQueryResult("SELECT 1")
        #expect(result.rows.count == 1)
        return client.currentHost.port
    }

    @Test func thePoolMovesToTheNextHostAndSaysSo() async throws {
        let (proxied, direct, proxy) = try setup()
        var configuration = proxied
        configuration.connectTimeout = 3
        configuration.additionalHosts = [PostgresHost(host: direct.host, port: direct.port)]
        try await proxy.setEnabled(true)
        let client = try await PostgresClient.connect(configuration: configuration)
        defer { client.close() }
        #expect(try await port(client) == proxied.port)
        let changes = client.hostChanges()
        let first = Task { () -> PostgresHostChange? in
            for await change in changes { return change }
            return nil
        }

        try await proxy.setEnabled(false)
        defer { Task { try? await proxy.setEnabled(true) } }
        let started = ContinuousClock.now
        #expect(try await port(client) == direct.port)
        #expect(ContinuousClock.now - started < .seconds(20), "fails over after connectTimeout")
        let change = await first.value
        #expect(change?.to == PostgresHost(host: direct.host, port: direct.port))
        #expect(change?.reason.contains("Can't reach the server") == true, "\(String(describing: change?.reason))")
        try await proxy.setEnabled(true)
    }

    @Test func aSingleUnreachableHostFailsWithinTheConnectTimeoutAndComesBack() async throws {
        let (proxied, _, proxy) = try setup()
        var configuration = proxied
        configuration.connectTimeout = 3
        try await proxy.setEnabled(true)
        let client = try await PostgresClient.connect(configuration: configuration)
        defer { client.close() }
        _ = try await port(client)

        try await proxy.setEnabled(false)
        let started = ContinuousClock.now
        do {
            _ = try await client.simpleQueryResult("SELECT 1")
            Issue.record("the only server is unreachable")
        } catch {
            #expect(ContinuousClock.now - started < .seconds(20))
            #expect(!error.localizedDescription.contains("CircuitBreaker"), "\(error)")
            #expect(error.localizedDescription.contains("Can't reach the server at \(proxied.host):\(proxied.port)"), "\(error)")
        }

        try await proxy.setEnabled(true)
        var recovered = false
        for _ in 0..<20 where !recovered {
            recovered = (try? await client.simpleQueryResult("SELECT 1")) != nil
            if !recovered { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(recovered, "the client comes back once the server answers again")
    }
}

/// A primary/standby pair: `POSTGRES_TEST_URL` (or `POSTGRES_TEST_TLS_URL`) is the primary, `POSTGRES_TEST_STANDBY_URL` the
/// standby. Which server each Connect To choice picks, and what the per-server probe reports.
@Suite(.testServer("POSTGRES_TEST_STANDBY_URL"))
struct StandbyTests {
    private func pair() throws -> (standby: PostgresConfiguration, primary: PostgresConfiguration) {
        let standby = try #require(TestServer.current).configuration
        // A TLS pair (`pg-17-primary-standby-tls-required`) names its primary in the TLS variable.
        let primaryURL = TestServer.url(TestServer.urlVariable) ?? TestServer.url("POSTGRES_TEST_TLS_URL")
        let primary = try #require(primaryURL, "\(TestServer.urlVariable) is the primary").configuration
        return (standby, primary)
    }

    private func chosen(_ attributes: PostgresTargetSessionAttributes, standby: PostgresConfiguration, primary: PostgresConfiguration) async throws -> PostgresHost {
        var configuration = standby
        configuration.additionalHosts = [PostgresHost(host: primary.host, port: primary.port)]
        configuration.targetSessionAttributes = attributes
        let client = try await PostgresClient.connect(configuration: configuration)
        defer { client.close() }
        return client.currentHost
    }

    @Test func connectToPicksThePrimaryOrTheStandby() async throws {
        let (standby, primary) = try pair()
        let primaryHost = PostgresHost(host: primary.host, port: primary.port), standbyHost = PostgresHost(host: standby.host, port: standby.port)
        #expect(try await chosen(.primary, standby: standby, primary: primary) == primaryHost)
        #expect(try await chosen(.readWrite, standby: standby, primary: primary) == primaryHost)
        #expect(try await chosen(.standby, standby: standby, primary: primary) == standbyHost)
        #expect(try await chosen(.preferStandby, standby: standby, primary: primary) == standbyHost)
        #expect(try await chosen(.any, standby: standby, primary: primary) == standbyHost)
    }

    @Test func theProbeSaysWhichIsWhich() async throws {
        let (standby, primary) = try pair()
        var configuration = primary
        configuration.additionalHosts = [PostgresHost(host: standby.host, port: standby.port)]
        let probes = await PostgresClient.probeHosts(configuration: configuration)
        #expect(probes.map(\.role) == [.primary, .standby], "\(probes.map { $0.error.map { "\($0)" } ?? "ok" })")
    }

    @Test func theStandbyIsInRecoveryAndThePrimaryListsIt() async throws {
        let (standby, primary) = try pair()
        let standbyClient = try await PostgresClient.connect(configuration: standby)
        defer { standbyClient.close() }
        #expect(try await standbyClient.metadata.isInRecovery())
        let primaryClient = try await PostgresClient.connect(configuration: primary)
        defer { primaryClient.close() }
        #expect(try await !primaryClient.metadata.listStandbys().isEmpty)
    }
}

/// Toxiproxy's HTTP API: switches the (single) proxy off and on.
struct Toxiproxy: Sendable {
    let control: String

    func setEnabled(_ enabled: Bool) async throws {
        let name = try await proxyName()
        var request = URLRequest(url: try #require(URL(string: "\(control)/proxies/\(name)")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"enabled": \#(enabled)}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        try await Task.sleep(for: .milliseconds(200))
    }

    private func proxyName() async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: try #require(URL(string: "\(control)/proxies")))
        let proxies = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(proxies.keys.sorted().first, "the proxy API lists no proxy")
    }
}
