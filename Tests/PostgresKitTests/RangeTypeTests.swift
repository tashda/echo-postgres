import XCTest
import Logging
@testable import PostgresKit

/// Tests range types: int4range, int8range, numrange, tsrange, tstzrange, daterange.
/// Tests containment, overlap, bound functions, empty ranges, and round-trips.
final class RangeTypeTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "RangeTypeTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() { client?.close(); super.tearDown() }

    // MARK: - Read All Range Types from SampleData

    func testAllRangeTypesExist() async throws {
        let rows = try await client.simpleQuery("SELECT count(*) FROM public.range_types WHERE col_int4range IS NOT NULL")
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThanOrEqual(count, 2)
    }

    func testInt4RangeValues() async throws {
        let rows = try await client.simpleQuery("SELECT col_int4range::text FROM public.range_types WHERE col_int4range IS NOT NULL AND col_int4range != 'empty' ORDER BY id")
        var ranges: [String] = []
        for try await r in rows.decode(String.self) { ranges.append(r) }
        XCTAssertTrue(ranges.contains("[1,10)"))
    }

    func testInt8RangeValues() async throws {
        let rows = try await client.simpleQuery("SELECT col_int8range::text FROM public.range_types WHERE col_int8range IS NOT NULL AND col_int8range != 'empty' ORDER BY id LIMIT 1")
        var found = false
        for try await r in rows.decode(String.self) {
            XCTAssertEqual(r, "[1,1000000)")
            found = true
        }
        XCTAssertTrue(found)
    }

    func testDateRangeValues() async throws {
        let rows = try await client.simpleQuery("SELECT col_daterange::text FROM public.range_types WHERE col_daterange IS NOT NULL AND col_daterange != 'empty' ORDER BY id LIMIT 1")
        var found = false
        for try await r in rows.decode(String.self) {
            XCTAssertTrue(r.contains("2024"))
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Containment @>

    func testContainmentOperator() async throws {
        let rows = try await client.simpleQuery("SELECT col_int4range::text FROM public.range_types WHERE col_int4range @> 5")
        var ranges: [String] = []
        for try await r in rows.decode(String.self) { ranges.append(r) }
        XCTAssertFalse(ranges.isEmpty, "Should find ranges containing 5")
    }

    func testContainedByOperator() async throws {
        let rows = try await client.simpleQuery("SELECT count(*) FROM public.range_types WHERE col_int4range <@ '[0,20)'::int4range")
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - Overlap &&

    func testOverlapOperator() async throws {
        let rows = try await client.simpleQuery("SELECT count(*) FROM public.range_types WHERE col_int4range && '[5,15)'::int4range")
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - Bound Functions

    func testLowerFunction() async throws {
        let rows = try await client.simpleQuery("SELECT lower(col_int4range) FROM public.range_types WHERE col_int4range = '[1,10)'")
        var found = false
        for try await val in rows.decode(Int.self) {
            XCTAssertEqual(val, 1)
            found = true
        }
        XCTAssertTrue(found)
    }

    func testUpperFunction() async throws {
        let rows = try await client.simpleQuery("SELECT upper(col_int4range) FROM public.range_types WHERE col_int4range = '[1,10)'")
        var found = false
        for try await val in rows.decode(Int.self) {
            XCTAssertEqual(val, 10)
            found = true
        }
        XCTAssertTrue(found)
    }

    func testIsEmptyFunction() async throws {
        let rows = try await client.simpleQuery("SELECT isempty(col_int4range) FROM public.range_types WHERE col_int4range = 'empty'")
        var found = false
        for try await val in rows.decode(Bool.self) {
            XCTAssertTrue(val)
            found = true
        }
        XCTAssertTrue(found)
    }

    func testIsEmptyFalseForNonEmpty() async throws {
        let rows = try await client.simpleQuery("SELECT isempty(col_int4range) FROM public.range_types WHERE col_int4range = '[1,10)'")
        var found = false
        for try await val in rows.decode(Bool.self) {
            XCTAssertFalse(val)
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Empty and NULL Ranges

    func testEmptyRange() async throws {
        let rows = try await client.simpleQuery("SELECT col_int4range::text FROM public.range_types WHERE col_int4range = 'empty'")
        var found = false
        for try await val in rows.decode(String.self) {
            XCTAssertEqual(val, "empty")
            found = true
        }
        XCTAssertTrue(found)
    }

    func testNullRange() async throws {
        let rows = try await client.simpleQuery("SELECT col_int4range IS NULL FROM public.range_types WHERE col_int4range IS NULL")
        var found = false
        for try await _ in rows { found = true }
        XCTAssertTrue(found)
    }

    // MARK: - Range INSERT and SELECT Round-trip

    func testRangeInsertRoundTrip() async throws {
        let table = "rt_range_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [
            .serial(name: "id", primaryKey: true),
            PostgresColumnDefinition(name: "r", dataType: "INT4RANGE")
        ])
        try await client.bulk.insert(into: table, columns: ["r"], values: [
            [.range("[10,20)")],
            [.range("[100,200]")],
            [.range("empty")]
        ])

        let rows = try await client.simpleQuery("SELECT r::text FROM \(table) ORDER BY id")
        var ranges: [String] = []
        for try await r in rows.decode(String.self) { ranges.append(r) }
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[0], "[10,20)")
        XCTAssertEqual(ranges[1], "[100,201)") // inclusive upper is normalized
        XCTAssertEqual(ranges[2], "empty")
    }

    // MARK: - Numeric Range

    func testNumericRangeContainment() async throws {
        let rows = try await client.simpleQuery("SELECT col_numrange::text FROM public.range_types WHERE col_numrange @> 50.0::numeric")
        var ranges: [String] = []
        for try await r in rows.decode(String.self) { ranges.append(r) }
        XCTAssertFalse(ranges.isEmpty)
    }

    // MARK: - Timestamp Range

    func testTimestampRangeOverlap() async throws {
        let rows = try await client.simpleQuery("""
            SELECT count(*) FROM public.range_types
            WHERE col_tstzrange && '[2024-06-01 00:00:00+00, 2024-07-01 00:00:00+00]'::tstzrange
        """)
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - Order valid_during in app.orders

    func testOrderValidDuringRange() async throws {
        let rows = try await client.simpleQuery("SELECT count(*) FROM app.orders WHERE valid_during IS NOT NULL")
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThan(count, 0, "Orders should have valid_during ranges")
    }

    func testOrderValidDuringContainment() async throws {
        let rows = try await client.simpleQuery("""
            SELECT count(*) FROM app.orders
            WHERE valid_during @> '2024-06-15 12:00:00+00'::timestamptz
        """)
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThanOrEqual(count, 0)
    }
}
