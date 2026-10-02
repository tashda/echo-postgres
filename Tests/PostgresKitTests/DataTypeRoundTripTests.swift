import XCTest
import Logging
@testable import PostgresKit

/// Systematic encode-insert-select-decode tests for every PostgreSQL data type.
/// Each test inserts a value via the client, reads it back, and asserts equality.
final class DataTypeRoundTripTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "DataTypeRoundTripTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() { client?.close(); super.tearDown() }

    // MARK: - Read from SampleData numeric_types

    func testNumericTypesFromSampleData() async throws {
        let rows = try await client.simpleQuery("SELECT col_smallint, col_integer, col_bigint FROM public.numeric_types WHERE col_smallint = 32767")
        var found = false
        for try await (s, i, b) in rows.decode((Int16, Int32, Int64).self) {
            XCTAssertEqual(s, 32767)
            XCTAssertEqual(i, 2147483647)
            XCTAssertEqual(b, 9223372036854775807)
            found = true
        }
        XCTAssertTrue(found)
    }

    func testNumericMinValues() async throws {
        let rows = try await client.simpleQuery("SELECT col_smallint, col_integer, col_bigint FROM public.numeric_types WHERE col_smallint = -32768")
        var found = false
        for try await (s, i, b) in rows.decode((Int16, Int32, Int64).self) {
            XCTAssertEqual(s, -32768)
            XCTAssertEqual(i, -2147483648)
            XCTAssertEqual(b, -9223372036854775808)
            found = true
        }
        XCTAssertTrue(found)
    }

    func testNumericZeroValues() async throws {
        let rows = try await client.simpleQuery("SELECT col_smallint, col_integer, col_bigint FROM public.numeric_types WHERE col_smallint = 0")
        var found = false
        for try await (s, i, b) in rows.decode((Int16, Int32, Int64).self) {
            XCTAssertEqual(s, 0)
            XCTAssertEqual(i, 0)
            XCTAssertEqual(b, 0)
            found = true
        }
        XCTAssertTrue(found)
    }

    func testNumericNullValues() async throws {
        let rows = try await client.simpleQuery("SELECT col_smallint, col_integer, col_bigint FROM public.numeric_types WHERE col_smallint IS NULL")
        var found = false
        for try await (s, i, b) in rows.decode((Int16?, Int32?, Int64?).self) {
            XCTAssertNil(s)
            XCTAssertNil(i)
            XCTAssertNil(b)
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Text Types

    func testTextTypesFromSampleData() async throws {
        let rows = try await client.simpleQuery("SELECT col_varchar, col_text FROM public.text_types WHERE col_varchar = 'Hello, World!'")
        var found = false
        for try await (varchar, text) in rows.decode((String, String).self) {
            XCTAssertEqual(varchar, "Hello, World!")
            XCTAssertTrue(text.contains("testing purposes"))
            found = true
        }
        XCTAssertTrue(found)
    }

    func testUnicodeTextRoundTrip() async throws {
        let rows = try await client.simpleQuery("SELECT col_varchar FROM public.text_types WHERE col_varchar LIKE '%日本語%'")
        var found = false
        for try await v in rows.decode(String.self) {
            XCTAssertTrue(v.contains("日本語"))
            XCTAssertTrue(v.contains("中文"))
            found = true
        }
        XCTAssertTrue(found)
    }

    func testEmptyStringRoundTrip() async throws {
        let rows = try await client.simpleQuery("SELECT col_varchar, col_text FROM public.text_types WHERE col_varchar = ''")
        var found = false
        for try await (v, t) in rows.decode((String, String).self) {
            XCTAssertEqual(v, "")
            XCTAssertEqual(t, "")
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Boolean

    func testBooleanRoundTrip() async throws {
        let rows = try await client.simpleQuery("SELECT col_boolean FROM public.special_types WHERE col_boolean IS NOT NULL ORDER BY id")
        var bools: [Bool] = []
        for try await b in rows.decode(Bool.self) { bools.append(b) }
        XCTAssertTrue(bools.contains(true))
        XCTAssertTrue(bools.contains(false))
    }

    // MARK: - UUID

    func testUUIDRoundTrip() async throws {
        let rows = try await client.simpleQuery("SELECT col_uuid FROM public.all_data_types WHERE col_uuid = 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'")
        var found = false
        for try await uuid in rows.decode(UUID.self) {
            XCTAssertEqual(uuid, UUID(uuidString: "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"))
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Temporal Types

    func testDateRoundTrip() async throws {
        let rows = try await client.simpleQuery("SELECT col_date FROM public.temporal_types WHERE col_date = '2024-01-15'")
        var found = false
        for try await _ in rows { found = true }
        XCTAssertTrue(found, "Should find the date value")
    }

    func testTimestampWithTimezone() async throws {
        let rows = try await client.simpleQuery("SELECT col_timestamp_tz FROM public.temporal_types WHERE col_date = '2024-01-15'")
        var found = false
        for try await _ in rows { found = true }
        XCTAssertTrue(found, "Should find timestamp with timezone")
    }

    // MARK: - JSON / JSONB

    func testJSONBFromSampleData() async throws {
        let rows = try await client.simpleQuery("SELECT col_jsonb->>'name' FROM public.json_types WHERE col_jsonb->>'name' = 'Alice'")
        var found = false
        for try await name in rows.decode(String.self) {
            XCTAssertEqual(name, "Alice")
            found = true
        }
        XCTAssertTrue(found)
    }

    func testNestedJSONBAccess() async throws {
        let rows = try await client.simpleQuery("SELECT col_jsonb->'users'->0->>'name' FROM public.json_types WHERE col_jsonb ? 'users'")
        var found = false
        for try await name in rows.decode(String.self) {
            XCTAssertEqual(name, "Alice")
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Network Types

    func testInetFromSampleData() async throws {
        let rows = try await client.simpleQuery("SELECT col_inet::text FROM public.network_types WHERE col_inet = '192.168.1.1'")
        var found = false
        for try await ip in rows.decode(String.self) {
            XCTAssertTrue(ip.contains("192.168.1.1"))
            found = true
        }
        XCTAssertTrue(found)
    }

    func testIPv6Inet() async throws {
        let rows = try await client.simpleQuery("SELECT col_inet::text FROM public.network_types WHERE col_inet = '::1'")
        var found = false
        for try await ip in rows.decode(String.self) {
            XCTAssertTrue(ip.contains("::1"))
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Array Types

    func testIntegerArrayFromSampleData() async throws {
        let rows = try await client.simpleQuery("SELECT col_int_arr::text FROM public.array_types WHERE col_int_arr = '{1,2,3,4,5}'")
        var found = false
        for try await arr in rows.decode(String.self) {
            XCTAssertEqual(arr, "{1,2,3,4,5}")
            found = true
        }
        XCTAssertTrue(found)
    }

    func testEmptyArrayFromSampleData() async throws {
        let rows = try await client.simpleQuery("SELECT col_int_arr::text FROM public.array_types WHERE col_int_arr = '{}'")
        var found = false
        for try await arr in rows.decode(String.self) {
            XCTAssertEqual(arr, "{}")
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Range Types

    func testInt4RangeFromSampleData() async throws {
        let rows = try await client.simpleQuery("SELECT col_int4range::text FROM public.range_types WHERE col_int4range = '[1,10)'")
        var found = false
        for try await r in rows.decode(String.self) {
            XCTAssertEqual(r, "[1,10)")
            found = true
        }
        XCTAssertTrue(found)
    }

    func testEmptyRangeFromSampleData() async throws {
        let rows = try await client.simpleQuery("SELECT col_int4range::text FROM public.range_types WHERE col_int4range = 'empty'")
        var found = false
        for try await r in rows.decode(String.self) {
            XCTAssertEqual(r, "empty")
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Full-Text Search Types

    func testTSVectorFromSampleData() async throws {
        let rows = try await client.simpleQuery("SELECT col_text FROM public.fulltext_types WHERE col_tsvector @@ to_tsquery('english', 'quick & fox')")
        var found = false
        for try await text in rows.decode(String.self) {
            XCTAssertTrue(text.contains("quick"))
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Binary Types

    func testByteaFromSampleData() async throws {
        let rows = try await client.simpleQuery("SELECT length(col_bytea) FROM public.binary_types WHERE col_bytea IS NOT NULL ORDER BY id LIMIT 1")
        var found = false
        for try await len in rows.decode(Int.self) {
            XCTAssertGreaterThan(len, 0)
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Insert and Read Back

    func testInsertAndReadBackInteger() async throws {
        let table = "rt_int_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [.integer(name: "val")])
        _ = try await client.bulk.insert(into: table, columns: ["val"], values: [[42]])

        let rows = try await client.simpleQuery("SELECT val FROM \(table)")
        var found = false
        for try await v in rows.decode(Int.self) {
            XCTAssertEqual(v, 42)
            found = true
        }
        XCTAssertTrue(found)
    }

    func testInsertAndReadBackText() async throws {
        let table = "rt_text_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [.text(name: "val")])
        _ = try await client.bulk.insert(into: table, columns: ["val"], values: [["Hello 日本語 🎉"]])

        let rows = try await client.simpleQuery("SELECT val FROM \(table)")
        var found = false
        for try await v in rows.decode(String.self) {
            XCTAssertEqual(v, "Hello 日本語 🎉")
            found = true
        }
        XCTAssertTrue(found)
    }

    func testInsertAndReadBackUUID() async throws {
        let table = "rt_uuid_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        let uuid = UUID()
        try await client.admin.createTable(name: table, columns: [.uuid(name: "val")])
        _ = try await client.bulk.insert(into: table, columns: ["val"], values: [[uuid]])

        let rows = try await client.simpleQuery("SELECT val FROM \(table)")
        var found = false
        for try await v in rows.decode(UUID.self) {
            XCTAssertEqual(v, uuid)
            found = true
        }
        XCTAssertTrue(found)
    }

    func testInsertAndReadBackBoolean() async throws {
        let table = "rt_bool_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [.boolean(name: "val")])
        _ = try await client.bulk.insert(into: table, columns: ["val"], values: [[true], [false]])

        let rows = try await client.simpleQuery("SELECT val FROM \(table) ORDER BY val")
        var bools: [Bool] = []
        for try await b in rows.decode(Bool.self) { bools.append(b) }
        XCTAssertEqual(bools, [false, true])
    }

    func testInsertAndReadBackDate() async throws {
        let table = "rt_date_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [.date(name: "val")])
        _ = try await client.bulk.insert(into: table, columns: ["val"], values: [[Date(timeIntervalSince1970: 0)]])

        let rows = try await client.simpleQuery("SELECT val::text FROM \(table)")
        var found = false
        for try await v in rows.decode(String.self) {
            XCTAssertEqual(v, "1970-01-01")
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - All-types Row

    func testAllDataTypesRowIsComplete() async throws {
        let rows = try await client.simpleQuery("""
            SELECT col_smallint, col_integer, col_bigint, col_boolean, col_varchar, col_uuid::text, col_mood::text
            FROM public.all_data_types WHERE col_uuid = 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'
        """)
        var found = false
        for try await (s, i, b, bo, v, u, m) in rows.decode((Int16, Int32, Int64, Bool, String, String, String).self) {
            XCTAssertEqual(s, 100)
            XCTAssertEqual(i, 200000)
            XCTAssertEqual(b, 9000000000)
            XCTAssertEqual(bo, true)
            XCTAssertEqual(v, "Test varchar")
            XCTAssertTrue(u.contains("a0eebc99"))
            XCTAssertEqual(m, "happy")
            found = true
        }
        XCTAssertTrue(found)
    }

    func testAllNullRow() async throws {
        // The second row in all_data_types has only col_smallint=1; col_integer/col_varchar are NULL,
        // but col_boolean has DEFAULT false and col_uuid has DEFAULT uuid_generate_v4().
        let rows = try await client.simpleQuery("""
            SELECT col_integer, col_varchar, col_text, col_bigint FROM public.all_data_types
            WHERE col_smallint = 1 AND col_integer IS NULL
        """)
        var found = false
        for try await (i, v, t, b) in rows.decode((Int32?, String?, String?, Int64?).self) {
            XCTAssertNil(i)
            XCTAssertNil(v)
            XCTAssertNil(t)
            XCTAssertNil(b)
            found = true
        }
        XCTAssertTrue(found)
    }
}
