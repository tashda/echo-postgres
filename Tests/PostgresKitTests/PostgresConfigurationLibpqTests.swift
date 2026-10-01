import Foundation
import PGLibpq
import PostgresKitTesting
import Testing
@testable import PostgresKit

@Suite("PostgresConfiguration as libpq keywords")
struct PostgresConfigurationLibpqTests {
    private func configuration(_ change: (inout PostgresConfiguration) -> Void = { _ in }) -> PostgresConfiguration {
        var configuration = PostgresConfiguration(host: "db.example.com", port: 5433, database: "app", username: "alice", password: "secret")
        change(&configuration)
        return configuration
    }

    @Test func basicKeywords() async throws {
        let parameters = try await configuration().libpqSetup(password: "secret").parameters
        #expect(parameters["host"] == "db.example.com")
        #expect(parameters["port"] == "5433")
        #expect(parameters["dbname"] == "app")
        #expect(parameters["user"] == "alice")
        #expect(parameters["password"] == "secret")
        #expect(parameters["application_name"] == "Echo")
        #expect(parameters["client_encoding"] == "UTF8")
        #expect(parameters["sslmode"] == "disable")
        #expect(parameters["gssencmode"] == "disable", "password sign-ins never try Kerberos encryption (D7)")
        #expect(parameters["target_session_attrs"] == "any")
        #expect(parameters["load_balance_hosts"] == "disable")
        #expect(parameters["options"] == "-c DateStyle=ISO -c IntervalStyle=postgres")
        #expect(!parameters.description.contains("secret"))
    }

    @Test func kerberosSignInMayEncryptWithKerberos() async throws {
        let parameters = try await configuration { $0.password = nil; $0.kerberosServiceName = "pgsvc" }.libpqSetup(password: nil).parameters
        #expect(parameters["gssencmode"] == "prefer")
        #expect(parameters["krbsrvname"] == "pgsvc")
        #expect(parameters["password"] == nil)
    }

    @Test func severalHostsInOrder() async throws {
        let parameters = try await configuration {
            $0.additionalHosts = [PostgresHost(host: "standby1", port: 5434), PostgresHost(host: "standby2")]
            $0.targetSessionAttributes = .readWrite
            $0.loadBalanceHosts = true
        }.libpqSetup(password: nil).parameters
        #expect(parameters["host"] == "db.example.com,standby1,standby2")
        #expect(parameters["port"] == "5433,5434,5432")
        #expect(parameters["target_session_attrs"] == "read-write")
        #expect(parameters["load_balance_hosts"] == "random")
    }

    @Test func timeoutsAndStartupParametersBecomeOptions() async throws {
        let parameters = try await configuration {
            $0.statementTimeout = .seconds(30)
            $0.lockTimeout = .milliseconds(1500)
            $0.idleInTransactionSessionTimeout = .seconds(600)
            $0.additionalStartupParameters = ["search_path": "app, public"]
        }.libpqSetup(password: nil).parameters
        #expect(parameters["options"] == "-c DateStyle=ISO -c IntervalStyle=postgres -c statement_timeout=30000 -c lock_timeout=1500 -c idle_in_transaction_session_timeout=600000 -c search_path=app,\\ public")
    }

    @Test func unixSocketFileBecomesFolderAndPort() async throws {
        let parameters = try await configuration { $0.unixSocketPath = "/tmp/.s.PGSQL.6543"; $0.sslMode = .require }.libpqSetup(password: nil).parameters
        #expect(parameters["host"] == "/tmp")
        #expect(parameters["port"] == "6543")
        #expect(parameters["sslmode"] == "disable")
    }

    @Test func kerberosServiceHostGoesToHostWithTheAddressInHostaddr() async throws {
        let parameters = try await configuration { $0.host = "127.0.0.1"; $0.kerberosServiceHost = "pg.corp.example" }.libpqSetup(password: nil).parameters
        #expect(parameters["host"] == "pg.corp.example")
        #expect(parameters["hostaddr"] == "127.0.0.1")
    }

    #if canImport(EchoTLS)
    @Test func verifyModesWithoutACAFileUseTheKeychainBundle() async throws {
        let full = try await configuration { $0.sslMode = .verifyFull }.libpqSetup(password: nil).parameters
        let bundle = try #require(full["sslrootcert"])
        #expect(bundle.contains("/Echo/TLS/trust-"))
        #expect(FileManager.default.fileExists(atPath: bundle))
        let chosen = try await configuration { $0.sslMode = .verifyCA; $0.sslRootCertPath = "/path/ca.pem" }.libpqSetup(password: nil).parameters
        #expect(chosen["sslrootcert"] == "/path/ca.pem")
        let require = try await configuration { $0.sslMode = .require }.libpqSetup(password: nil).parameters
        #expect(require["sslrootcert"] == nil, "no verification: the transport points it at a missing file")
    }

    @Test func noClientCertificateMeansNoneIsSent() async throws {
        let parameters = try await configuration { $0.sslMode = .require }.libpqSetup(password: nil).parameters
        #expect(parameters["sslcertmode"] == "disable")
        #expect(parameters["sslcert"] == nil)
    }

    @Test func missingClientCertificateFileIsAnError() async {
        await #expect(throws: (any Error).self) {
            _ = try await configuration { $0.sslMode = .require; $0.sslCertPath = "/nonexistent/client.pem"; $0.sslKeyPath = "/nonexistent/client.key" }
                .libpqSetup(password: nil)
        }
    }
    #endif
}

@Suite("PostgresConfiguration connects through libpq", .testServer)
struct PostgresConfigurationLibpqLabTests {
    @Test func connectsWithTheMappedKeywords() async throws {
        let server = try #require(TestServer.current)
        let setup = try await server.configuration.libpqSetup(password: server.configuration.password)
        let connection = try await PGConnection.connect(setup.parameters, timeout: .seconds(15))
        defer { Task { await connection.close() } }
        let row = try #require(try await connection.execute(
            "SELECT current_setting('application_name'), current_setting('DateStyle'), current_setting('IntervalStyle')"
        ).first)
        #expect(row.string(row: 0, column: 0) == server.configuration.applicationName)
        #expect(row.string(row: 0, column: 1)?.hasPrefix("ISO") == true)
        #expect(row.string(row: 0, column: 2) == "postgres")
    }
}
