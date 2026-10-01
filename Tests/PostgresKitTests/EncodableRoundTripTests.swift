import XCTest
import Logging
@testable import PostgresKit

/// Integration tests for custom PostgresEncodable types (IPAddress, MACAddress).
/// Verifies that postgresBind() produces parameters that PostgreSQL accepts and returns correctly.
final class EncodableRoundTripTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else {
            throw XCTSkip("POSTGRES_HOST not set. Copy .env.example to .env and configure connection.")
        }
        let config = PostgresConfiguration(
            host: TestEnv.host,
            port: TestEnv.port,
            database: TestEnv.database,
            username: TestEnv.username,
            password: TestEnv.password,
            useTLS: TestEnv.useTLS,
            applicationName: "EncodableRoundTripTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() async throws {
        client?.close()
    }

    // MARK: - IPAddress

    func testIPAddressV4_EncodeAndQueryRoundTrip() async throws {
        let ip = IPAddress(string: "192.168.1.100")
        let encoded = ip.postgresBind()

        let result = try await client.withConnection { conn in
            try await conn.query("SELECT $1::inet::text AS addr", binds: [encoded])
        }
        var returned = ""
        for try await v in result.decode(String.self) { returned = v; break }

        XCTAssertTrue(returned.contains("192.168.1.100"),
                      "Returned address '\(returned)' should contain the original IP")
    }

    func testIPAddressV6_EncodeAndQueryRoundTrip() async throws {
        let ip = IPAddress(string: "::1")
        let encoded = ip.postgresBind()

        let result = try await client.withConnection { conn in
            try await conn.query("SELECT $1::inet::text AS addr", binds: [encoded])
        }
        var returned = ""
        for try await v in result.decode(String.self) { returned = v; break }
        XCTAssertFalse(returned.isEmpty, "IPv6 address should be returned by PostgreSQL")
    }

    func testIPAddressCIDR_EncodeAndQueryRoundTrip() async throws {
        let ip = IPAddress(string: "10.0.0.0/8")
        let encoded = ip.postgresBind()

        let result = try await client.withConnection { conn in
            try await conn.query("SELECT $1::inet::text AS addr", binds: [encoded])
        }
        var returned = ""
        for try await v in result.decode(String.self) { returned = v; break }
        XCTAssertTrue(returned.contains("10"), "CIDR range should be accepted and returned")
    }

    func testIPAddressInsertAndSelectFromTable() async throws {
        let table = "pgwire_ip_test_\(UInt32.random(in: 0..<UInt32.max))"
        try await client.admin.createTable(
            name: table,
            columns: [
                .serial(name: "id", primaryKey: true),
                .inet(name: "addr")
            ]
        )
        defer {
            Task.detached { [client = self.client!] in
                try? await client.admin.dropTable(name: table, ifExists: true)
            }
        }

        let testIP = IPAddress(string: "172.16.0.1")
        let insertRow: [PostgresInsertValue] = [.inet(testIP.string)]
        let insertValues = [insertRow]
        try await client.withConnection { conn in
            _ = try await conn.insert(into: table, columns: ["addr"], values: insertValues)
        }

        let rows = try await client.simpleQuery("SELECT addr::text FROM \(table)")
        var addrs: [String] = []
        for try await addr in rows.decode(String.self) { addrs.append(addr) }

        XCTAssertEqual(addrs.count, 1)
        XCTAssertTrue(addrs[0].contains("172.16.0.1"), "Stored IP should be retrieved correctly")
    }

    func testIPAddressDataTypeIsInet() {
        let ip = IPAddress(string: "1.2.3.4")
        XCTAssertEqual(ip.postgresBind().parameter.typeOID, 869)
    }

    // MARK: - MACAddress

    /// MAC text goes to the server as is; the server parses every MAC format and rejects the rest.
    func testMACAddress_InvalidFormatIsRejectedByTheServer() async throws {
        for text in ["not-a-mac", "AA:BB:CC"] {
            let bind = MACAddress(string: text).postgresBind()
            do {
                _ = try await client.withConnection { try await $0.queryResult("SELECT $1::macaddr::text", binds: [bind]) }
                XCTFail("\(text) was accepted")
            } catch let error as PostgresKit.PostgresError {
                XCTAssertEqual(error.sqlState, "22P02")
            }
        }
    }

    func testMACAddress_InsertAndSelectFromTable() async throws {
        let table = "pgwire_mac_test_\(UInt32.random(in: 0..<UInt32.max))"
        try await client.admin.createTable(
            name: table,
            columns: [
                .serial(name: "id", primaryKey: true),
                .macaddr(name: "addr")
            ]
        )
        defer {
            Task.detached { [client = self.client!] in
                try? await client.admin.dropTable(name: table, ifExists: true)
            }
        }

        let mac = MACAddress(string: "12:34:56:78:9a:bc")
        let insertRow: [PostgresInsertValue] = [.macaddr(mac.string)]
        let insertValues = [insertRow]
        try await client.withConnection { conn in
            _ = try await conn.insert(into: table, columns: ["addr"], values: insertValues)
        }

        let rows = try await client.simpleQuery("SELECT addr::text FROM \(table)")
        var addrs: [String] = []
        for try await addr in rows.decode(String.self) { addrs.append(addr) }

        XCTAssertEqual(addrs.count, 1)
        XCTAssertFalse(addrs[0].isEmpty, "Stored MAC address should be returned")
        XCTAssertTrue(addrs[0].contains(":"), "Returned value should be in MAC address format")
    }

    func testMACAddress_DataTypeIsMacaddr() {
        let mac = MACAddress(string: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(mac.postgresBind().parameter.typeOID, 829)
    }

    // MARK: - Multiple Encodable Types Together

    func testMultipleEncodableTypesInQuery() async throws {
        let ip = IPAddress(string: "192.168.0.1")
        let encodedIP = ip.postgresBind()

        let result = try await client.withConnection { conn in
            try await conn.query(
                "SELECT $1::inet::text AS ip, $2::text AS name",
                binds: [encodedIP, PostgresBind.text("test")]
            )
        }

        var count = 0
        for try await _ in result.decode((String, String).self) { count += 1 }
        XCTAssertEqual(count, 1, "Should return exactly one row")
    }
}
