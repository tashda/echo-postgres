import Foundation
import Logging
import XCTest
@testable import PostgresKit

/// For each expression, formats the binary cell with ``PostgresCellFormatter`` and compares it with
/// the server's own output function (`format('%s', …)`) of the same value. This is what guarantees that a results grid
/// shows exactly what `psql` would.
final class FormatterServerParityTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        client = try await PostgresKit.PostgresClient.connect(configuration: TestEnv.configuration(applicationName: "FormatterParity"), logger: logger)
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    private static let expressions: [String] = [
        // Numbers
        "42::int2", "'-2147483648'::int4", "9223372036854775807::int8",
        "1.5::float8", "2::float8", "1e20::float8", "0.0001::float8", "0.00001::float8", "123456789012345::float8",
        "1e15::float8", "1e16::float8", "'-0.1'::float8", "'NaN'::float8", "'-Infinity'::float8", "3.4028235e38::float4",
        "0.1::float4", "1234567::float4",
        "123.450::numeric", "-0.0005::numeric", "0::numeric", "100000000::numeric", "'NaN'::numeric", "'Infinity'::numeric",
        "12345678901234567890123456789012345678901234.5678901234::numeric", "1.10::numeric(10,4)",
        // Text-like
        "'héllo wörld'::text", "''::text", "'x'::\"char\"", "'name'::name", "'padded'::char(10)", "'<a b=\"1\"/>'::xml",
        "'{\"a\": [1, 2, {\"b\": null}]}'::json", "'{\"b\": 2, \"a\": [1, \"x\"]}'::jsonb", "'$.a[*] ? (@ > 1)'::jsonpath",
        // Binary-ish
        "'\\x00ff10'::bytea", "'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid", "B'1011'::bit(4)", "B'1111111101'::varbit",
        "42::oid", "'16/B374D848'::pg_lsn", "'(1,2)'::tid",
        // Temporal
        "'2024-02-29'::date", "'0044-03-15 BC'::date", "'infinity'::date", "'-infinity'::date",
        "'2024-02-29 13:45:01.123456'::timestamp", "'1999-12-31 23:59:59.5'::timestamp", "'0100-01-01 00:00:00 BC'::timestamp",
        "'infinity'::timestamp", "'2024-06-01 12:00:00+02'::timestamptz", "'-infinity'::timestamptz",
        "'12:34:56.000001'::time", "'24:00:00'::time", "'12:00:00+02'::timetz", "'00:00:00-05:30'::timetz",
        "'1 day 02:03:04'::interval", "'1 year 2 mons'::interval", "'-1 hour'::interval", "'1 day -1 hour'::interval",
        "'-1 mons 100 hours'::interval", "'0.5 seconds'::interval", "'0'::interval", "'-1 year -2 days 03:00'::interval",
        // Network
        "'192.168.1.10'::inet", "'192.168.1.10/24'::inet", "'10.0.0.0/8'::cidr", "'::1'::inet", "'::ffff:1.2.3.4'::inet",
        "'2001:db8::/64'::cidr", "'fe80::1:2:3:4'::inet", "'2001:db8:0:0:1:0:0:1'::inet",
        "'08:00:2b:01:02:03'::macaddr", "'08:00:2b:01:02:03:04:05'::macaddr8",
        // Geometry
        "point(1.5, 2)", "'[(0,0),(1,1)]'::lseg", "'((0,0),(1,1))'::box", "'[(0,0),(1,1),(2,0)]'::path", "'((0,0),(1,1),(2,0))'::path",
        "'((0,0),(1,1),(2,0))'::polygon", "'{1,-1,0}'::line", "'<(0,0),3>'::circle",
        // Text search
        "to_tsvector('english', 'The fat rats ate the cats')", "'a:1A b:2B,3 c'::tsvector", "$$'it''s' 'back\\\\slash'$$::tsvector",
        "'fat & (rat | cat)'::tsquery", "'!(a & b)'::tsquery", "'a <-> b'::tsquery", "'a <2> (b | c)'::tsquery", "'sup:*A & !x'::tsquery",
        "'(a <-> b) <-> c'::tsquery", "'a <-> (b <-> c)'::tsquery",
        // Arrays
        "ARRAY[1, 2, NULL]::int4[]", "ARRAY['a b', '', 'null', 'q\"\\\\']::text[]", "'{{1,2},{3,4}}'::int[]", "'[0:1]={1,2}'::int[]",
        "'{}'::int[]", "ARRAY['2024-01-01'::date, 'infinity']", "ARRAY['1 day'::interval]", "ARRAY[point(1,2), point(3,4)]",
        "ARRAY['((0,0),(1,1))'::box, '((2,2),(3,3))'::box]", "ARRAY[1.5, NULL, 'NaN']::numeric[]",
        "ARRAY['192.168.0.1'::inet]", "ARRAY['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid]", "ARRAY[ARRAY['x','y']]",
        "'1 2 3'::int2vector", "'10 20'::oidvector",
        // Ranges and multiranges
        "int4range(1, 10)", "'empty'::int4range", "'(,5]'::int8range", "numrange(1.5, 2.5, '[]')",
        "tsrange('2024-01-01', '2024-01-02')", "daterange('2024-01-01', NULL)", "'{[1,3), [5,7)}'::int4multirange",
        "ARRAY[int4range(1,2), int4range(3,4)]",
        // Records and composites
        "ROW(1, 'a b', NULL, ARRAY[1,2])", "ROW(ROW(1, 'x'), '')",
        // Extension and user types from SampleData (run-time OIDs)
        "'happy'::mood", "ARRAY['happy', 'sad']::mood[]", "'a=>1, b=>NULL, \"c d\"=>\"e f\"'::hstore",
        "'top.science.astronomy'::ltree", "'MiXeD'::citext", "42::positive_integer",
    ]

    func testEveryTypeMatchesServerText() async throws {
        let formatter = PostgresCellFormatter(timeZone: TimeZone(identifier: "UTC")!)
        let mismatches = try await client.withConnection { connection -> [String] in
            _ = try await connection.simpleQuery("SET TimeZone = 'UTC'").collect()
            var mismatches: [String] = []
            for expression in Self.expressions {
                let rows: [PostgresRow]
                do {
                    rows = try await connection.simpleQuery("SELECT \(expression) AS v, format('%s', \(expression)) AS t").collect()
                } catch {
                    mismatches.append("\(expression): query failed: \(String(reflecting: error))")
                    continue
                }
                guard let row = rows.first else { mismatches.append("\(expression): no row"); continue }
                let cells = Array(row)
                let formatted = formatter.stringValue(for: cells[0])
                let server = formatter.stringValue(for: cells[1])
                if formatted != server {
                    mismatches.append("\(expression)\n    formatter: \(formatted ?? "NULL")\n    server:    \(server ?? "NULL")")
                }
            }
            return mismatches
        }
        XCTAssert(mismatches.isEmpty, "Formatter differs from server text for \(mismatches.count) value(s):\n" + mismatches.joined(separator: "\n"))
    }

    func testDeliberateDifferences() async throws {
        let formatter = PostgresCellFormatter(timeZone: TimeZone(identifier: "UTC")!)
        let values = try await client.withConnection { connection -> [String?] in
            let rows = try await connection.simpleQuery("SELECT true, false, 12.34::money, '-0.05'::money, 'pg_class'::regclass, ARRAY[true, false]").collect()
            return rows.first.map { Array($0).map(formatter.stringValue(for:)) } ?? []
        }
        XCTAssertEqual(values[0], "true")
        XCTAssertEqual(values[1], "false")
        XCTAssertEqual(values[2], "12.34")
        XCTAssertEqual(values[3], "-0.05")
        XCTAssertEqual(values[4], "1259", "reg* types show the OID")
        XCTAssertEqual(values[5], "{true,false}", "booleans read the same inside arrays as on their own")
    }

    func testSpoolPathMatchesLivePath() async throws {
        // Echo stores rows as raw bytes + OID and formats them later: that must equal the live cell.
        let formatter = PostgresCellFormatter()
        let pairs = try await client.withConnection { connection -> [(String?, String?)] in
            let rows = try await connection.simpleQuery("SELECT 251, now(), ARRAY[1,2], interval '1 day', NULL::text, ''::text").collect()
            guard let row = rows.first else { return [] }
            return row.map { cell in
                let data = cell.bytes.map { buffer in buffer.withUnsafeReadableBytes { Data($0) } }
                return (formatter.stringValue(for: cell), formatter.stringValue(oid: cell.dataType.rawValue, data: data))
            }
        }
        XCTAssertEqual(pairs.count, 6)
        for (live, spooled) in pairs { XCTAssertEqual(live, spooled) }
        XCTAssertEqual(pairs[0].0, "251")
    }
}
