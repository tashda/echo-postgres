import Foundation
import PostgresKit
import PostgresKitTesting
import Testing

/// The test-server URL convention (TESTING.md): every URL form, percent-encoded user info, missing
/// variables and POSTGRES_TEST_REQUIRED. No server needed.
@Suite struct TestServerURLTests {
    @Test func aPlainServer() throws {
        let server = try TestServer.parse("postgres://postgres:pass@localhost:5432/postgres?sslmode=disable")
        let configuration = server.configuration
        #expect(configuration.host == "localhost")
        #expect(configuration.port == 5432)
        #expect(configuration.database == "postgres")
        #expect(configuration.username == "postgres")
        #expect(configuration.password == "pass")
        #expect(configuration.sslMode == .disable)
        #expect(!server.usesKerberos)
    }

    @Test func aTLSServerWithCAAndClientCertificate() throws {
        let configuration = try TestServer.parse(
            "postgres://postgres:pass@host:5432/postgres?sslmode=verify-full&sslrootcert=/ca.pem&sslcert=/c.pem&sslkey=/k.pem&sslpassword=secret"
        ).configuration
        #expect(configuration.sslMode == .verifyFull)
        #expect(configuration.sslRootCertPath == "/ca.pem")
        #expect(configuration.sslCertPath == "/c.pem")
        #expect(configuration.sslKeyPath == "/k.pem")
        #expect(configuration.sslKeyPassword == "secret")
    }

    @Test func aKerberosLogin() throws {
        let server = try TestServer.parse(
            "postgres://alice%40LAB.TEST@host:5432/postgres?sslmode=disable&authentication=kerberos&serviceHost=pg.lab.test&krb5Config=/krb5.conf")
        #expect(server.usesKerberos)
        #expect(server.kerberosPrincipal == "alice@LAB.TEST")
        #expect(server.configuration.username == "alice", "the role include_realm=0 maps the principal to")
        #expect(server.configuration.password == nil)
        #expect(server.configuration.kerberosServiceHost == "pg.lab.test")
        #expect(server.configuration.kerberosServiceName == "postgres")
        #expect(server.kerberosConfigPath == "/krb5.conf")
    }

    @Test(arguments: [
        ("p%40ss%3Aw%2Ford", "p@ss:w/ord"),   // percent-encoded @ : /
        ("p@ss", "p@ss"),                    // an unencoded @ in the password
        ("%25%20x", "% x"),
    ])
    func passwordsWithDelimiters(encoded: String, decoded: String) throws {
        let configuration = try TestServer.parse("postgres://user%3Aname:\(encoded)@db.example.com:6543/sales").configuration
        #expect(configuration.username == "user:name")
        #expect(configuration.password == decoded)
        #expect(configuration.host == "db.example.com")
        #expect(configuration.port == 6543)
        #expect(configuration.database == "sales")
    }

    @Test func defaultsAndOtherSpellings() throws {
        let configuration = try TestServer.parse("postgresql://postgres@[::1]?krbsrvname=pg&target_session_attrs=read-write&connect_timeout=3&application_name=x%20y").configuration
        #expect(configuration.host == "::1")
        #expect(configuration.port == 5432)
        #expect(configuration.database == "postgres")
        #expect(configuration.password == nil)
        #expect(configuration.sslMode == .prefer, "libpq's default")
        #expect(configuration.kerberosServiceName == "pg")
        #expect(configuration.targetSessionAttributes == .readWrite)
        #expect(configuration.connectTimeout == 3)
        #expect(configuration.applicationName == "x y")
    }

    @Test(arguments: ["mysql://root@localhost/", "localhost:5432", "postgres://user@host:99999/db",
                      "postgres://user@host/db?sslmode=sometimes", "postgres://:pass@host/db"])
    func malformedURLsAreRefused(_ text: String) {
        #expect(throws: TestServerURLError.self) { try TestServer.parse(text) }
    }

    @Test func aMissingVariableGivesNoServerAndAMessageNamingIt() {
        #expect(TestServer.url("POSTGRES_TEST_TLS_URL", environment: [:]) == nil)
        #expect(TestServer.url("POSTGRES_TEST_URL", environment: ["POSTGRES_TEST_URL": "  "]) == nil)
        #expect(TestServer.url("POSTGRES_TEST_URL", environment: ["POSTGRES_TEST_URL": "postgres://u@h/d"])?.variable == "POSTGRES_TEST_URL")
        #expect(TestServer.missingMessage("POSTGRES_TEST_TLS_URL").contains("POSTGRES_TEST_TLS_URL"))
    }

    @Test func requiredOnlyWithOne() {
        #expect(TestServer.isRequired(environment: ["POSTGRES_TEST_REQUIRED": "1"]))
        #expect(!TestServer.isRequired(environment: ["POSTGRES_TEST_REQUIRED": "0"]))
        #expect(!TestServer.isRequired(environment: [:]))
    }
}
