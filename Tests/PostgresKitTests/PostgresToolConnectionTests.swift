import Foundation
import PGLibpq
import Testing
@testable import PostgresKit

/// The bundled tools connect as the connection does (Echo #34), with the password kept off the
/// command line.
@Suite("Connection string for the PostgreSQL tools")
struct PostgresToolConnectionTests {
    private func configuration(_ change: (inout PostgresConfiguration) -> Void = { _ in }) -> PostgresConfiguration {
        var configuration = PostgresConfiguration(host: "db.example.com", port: 5433, database: "app", username: "alice", password: "s3cret")
        change(&configuration)
        return configuration
    }

    @Test func keywordsWithoutThePassword() async throws {
        let tool = try await configuration { $0.sslMode = .verifyFull; $0.sslRootCertPath = "/certs/ca.pem" }.toolConnection(database: "other")
        #expect(tool.connectionString.contains("host='db.example.com'"))
        #expect(tool.connectionString.contains("port='5433'"))
        #expect(tool.connectionString.contains("dbname='other'"))
        #expect(tool.connectionString.contains("sslmode='verify-full'"))
        #expect(tool.connectionString.contains("sslrootcert='/certs/ca.pem'"))
        #expect(tool.connectionString.contains("passfile='/var/empty/echo-no-file'"), "no ~/.pgpass")
        #expect(!tool.connectionString.contains("s3cret"))
        #expect(tool.environment == ["PGPASSWORD": "s3cret"])
    }

    @Test func severalHostsAndQuotes() async throws {
        let tool = try await configuration {
            $0.database = "it's\\here"
            $0.additionalHosts = [PostgresHost(host: "standby.example.com", port: 5434)]
            $0.targetSessionAttributes = .readWrite
        }.toolConnection()
        #expect(tool.connectionString.contains("host='db.example.com,standby.example.com'"))
        #expect(tool.connectionString.contains("port='5433,5434'"))
        #expect(tool.connectionString.contains("target_session_attrs='read-write'"))
        #expect(tool.connectionString.contains("dbname='it\\'s\\\\here'"))
    }

    @Test func kerberosHasNoPassword() async throws {
        let tool = try await configuration { $0.password = nil; $0.kerberosServiceName = "postgres" }.toolConnection()
        #expect(tool.environment.isEmpty)
        #expect(tool.connectionString.contains("gssencmode='prefer'"))
    }
}
