import Foundation
import XCTest
@testable import PostgresWire

/// Hand-built binary wire values → expected Postgres text output.
/// `FormatterServerParityTests` (PostgresKitTests) checks the same code against a real server.
final class PostgresBinaryFormatterTests: XCTestCase {
    private let formatter = PostgresBinaryFormatter(timeZone: TimeZone(identifier: "UTC")!)

    private func format(_ oid: UInt32, _ bytes: [UInt8]) -> String {
        formatter.string(oid: oid, data: Data(bytes))
    }

    private func be<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private func float8(_ value: Double) -> [UInt8] { be(value.bitPattern) }

    // MARK: - Scalars

    func testIntegersAreBigEndian() {
        XCTAssertEqual(format(23, be(Int32(251))), "251")
        XCTAssertEqual(format(21, be(Int16(-7))), "-7")
        XCTAssertEqual(format(20, be(Int64.max)), "9223372036854775807")
        XCTAssertEqual(format(26, be(UInt32.max)), "4294967295")
    }

    func testBoolAndText() {
        XCTAssertEqual(format(16, [1]), "true")
        XCTAssertEqual(format(16, [0]), "false")
        XCTAssertEqual(format(25, Array("héllo".utf8)), "héllo")
        XCTAssertEqual(format(25, []), "")
    }

    func testFloatsUseServerLayout() {
        XCTAssertEqual(format(701, float8(2.0)), "2")
        XCTAssertEqual(format(701, float8(1.5)), "1.5")
        XCTAssertEqual(format(701, float8(1e20)), "1e+20")
        XCTAssertEqual(format(701, float8(0.0001)), "0.0001")
        XCTAssertEqual(format(701, float8(0.00001)), "1e-05")
        XCTAssertEqual(format(701, float8(123456789012345680)), "1.2345678901234568e+17")
        XCTAssertEqual(format(701, float8(.nan)), "NaN")
        XCTAssertEqual(format(701, float8(-.infinity)), "-Infinity")
        XCTAssertEqual(format(700, be(Float(1234567).bitPattern)), "1.234567e+06")
        XCTAssertEqual(format(700, be(Float(0.1).bitPattern)), "0.1")
    }

    func testNumericIsExact() {
        // 123.450 → ndigits 2, weight 0, sign +, dscale 3, digits [123, 4500]
        XCTAssertEqual(format(1700, be(Int16(2)) + be(Int16(0)) + be(UInt16(0)) + be(UInt16(3)) + be(Int16(123)) + be(Int16(4500))), "123.450")
        // -0.0005 → weight -1, digits [5], dscale 4
        XCTAssertEqual(format(1700, be(Int16(1)) + be(Int16(-1)) + be(UInt16(0x4000)) + be(UInt16(4)) + be(Int16(5))), "-0.0005")
        // 100000000 (1 * 10000^2) → weight 2, digits [1]
        XCTAssertEqual(format(1700, be(Int16(1)) + be(Int16(2)) + be(UInt16(0)) + be(UInt16(0)) + be(Int16(1))), "100000000")
        // More than 38 significant digits survive (Decimal would round).
        let digits: [Int16] = [1234, 5678, 9012, 3456, 7890, 1234, 5678, 9012, 3456, 7890, 1234]
        let bytes = be(Int16(11)) + be(Int16(10)) + be(UInt16(0)) + be(UInt16(0)) + digits.flatMap(be)
        XCTAssertEqual(format(1700, bytes), "12345678901234567890123456789012345678901234")
        XCTAssertEqual(format(1700, be(Int16(0)) + be(Int16(0)) + be(UInt16(0xC000)) + be(UInt16(0))), "NaN")
        XCTAssertEqual(format(1700, be(Int16(0)) + be(Int16(0)) + be(UInt16(0xF000)) + be(UInt16(0))), "-Infinity")
    }

    func testMoneyUuidByteaChar() {
        XCTAssertEqual(format(790, be(Int64(1234))), "12.34")
        XCTAssertEqual(format(790, be(Int64(-5))), "-0.05")
        XCTAssertEqual(format(2950, [0xA0, 0xEE, 0xBC, 0x99, 0x9C, 0x0B, 0x4E, 0xF8, 0xBB, 0x6D, 0x6B, 0xB9, 0xBD, 0x38, 0x0A, 0x11]),
                       "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")
        XCTAssertEqual(format(17, [0x61, 0x62, 0x00, 0xFF]), "\\x616200ff")
        XCTAssertEqual(format(18, [0x78]), "x")
        XCTAssertEqual(format(3802, [1] + Array("{\"a\": 1}".utf8)), "{\"a\": 1}")
    }

    // MARK: - Temporal

    func testDates() {
        XCTAssertEqual(format(1082, be(Int32(0))), "2000-01-01")
        XCTAssertEqual(format(1082, be(Int32(-1))), "1999-12-31")
        // 0044-03-15 BC is Julian day 1705428 (Postgres date2j); the epoch is day 2451545.
        XCTAssertEqual(format(1082, be(Int32(1_705_428 - 2_451_545))), "0044-03-15 BC")
        XCTAssertEqual(format(1082, be(Int32.max)), "infinity")
        XCTAssertEqual(format(1082, be(Int32.min)), "-infinity")
    }

    func testTimestamps() {
        let oneDay: Int64 = 86_400_000_000
        XCTAssertEqual(format(1114, be(Int64(0))), "2000-01-01 00:00:00")
        XCTAssertEqual(format(1114, be(oneDay + 3_723_500_000)), "2000-01-02 01:02:03.5")
        XCTAssertEqual(format(1114, be(Int64(-1))), "1999-12-31 23:59:59.999999")
        XCTAssertEqual(format(1114, be(Int64.max)), "infinity")
        XCTAssertEqual(format(1184, be(Int64(0))), "2000-01-01 00:00:00+00")
        let berlin = PostgresBinaryFormatter(timeZone: TimeZone(identifier: "Europe/Berlin")!)
        XCTAssertEqual(berlin.string(oid: 1184, data: Data(be(Int64(0)))), "2000-01-01 01:00:00+01")
        let kolkata = PostgresBinaryFormatter(timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        XCTAssertEqual(kolkata.string(oid: 1184, data: Data(be(Int64(0)))), "2000-01-01 05:30:00+05:30")
    }

    func testTimesAndIntervals() {
        XCTAssertEqual(format(1083, be(Int64(45_296_000_001))), "12:34:56.000001")
        // timetz zone is seconds WEST of UTC: +02 is stored as -7200.
        XCTAssertEqual(format(1266, be(Int64(43_200_000_000)) + be(Int32(-7200))), "12:00:00+02")
        XCTAssertEqual(format(1266, be(Int64(0)) + be(Int32(19800 + 1800))), "00:00:00-06")
        func interval(_ micros: Int64, _ days: Int32, _ months: Int32) -> String {
            format(1186, be(micros) + be(days) + be(months))
        }
        XCTAssertEqual(interval(7_384_000_000, 1, 0), "1 day 02:03:04")
        XCTAssertEqual(interval(0, 0, 14), "1 year 2 mons")
        XCTAssertEqual(interval(0, 0, 0), "00:00:00")
        XCTAssertEqual(interval(-3_600_000_000, 0, 0), "-01:00:00")
        XCTAssertEqual(interval(3_600_000_000, -1, 0), "-1 days +01:00:00")
        XCTAssertEqual(interval(360_000_000_000, 0, -1), "-1 mons +100:00:00")
        XCTAssertEqual(interval(500_000, 0, 0), "00:00:00.5")
    }

    // MARK: - Network, geometry, bits

    func testInet() {
        XCTAssertEqual(format(869, [2, 32, 0, 4, 192, 168, 1, 10]), "192.168.1.10")
        XCTAssertEqual(format(869, [2, 24, 0, 4, 192, 168, 1, 10]), "192.168.1.10/24")
        XCTAssertEqual(format(650, [2, 8, 1, 4, 10, 0, 0, 0]), "10.0.0.0/8")
        let loopback: [UInt8] = Array(repeating: 0, count: 15) + [1]
        XCTAssertEqual(format(869, [3, 128, 0, 16] + loopback), "::1")
        let mapped: [UInt8] = Array(repeating: 0, count: 10) + [0xFF, 0xFF, 1, 2, 3, 4]
        XCTAssertEqual(format(869, [3, 128, 0, 16] + mapped), "::ffff:1.2.3.4")
        let docs: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        XCTAssertEqual(format(650, [3, 64, 1, 16] + docs), "2001:db8::1/64")
        XCTAssertEqual(format(829, [8, 0, 0x2B, 1, 2, 3]), "08:00:2b:01:02:03")
    }

    func testGeometry() {
        XCTAssertEqual(format(600, float8(1.5) + float8(2)), "(1.5,2)")
        XCTAssertEqual(format(718, float8(0) + float8(0) + float8(3)), "<(0,0),3>")
        XCTAssertEqual(format(603, float8(2) + float8(2) + float8(0) + float8(0)), "(2,2),(0,0)")
        XCTAssertEqual(format(602, [0] + be(Int32(2)) + float8(0) + float8(0) + float8(1) + float8(1)), "[(0,0),(1,1)]")
        XCTAssertEqual(format(628, float8(1) + float8(-1) + float8(0)), "{1,-1,0}")
    }

    func testBits() {
        XCTAssertEqual(format(1560, be(Int32(4)) + [0b1011_0000]), "1011")
        XCTAssertEqual(format(1562, be(Int32(10)) + [0xFF, 0b0100_0000]), "1111111101")
    }

    // MARK: - Containers

    private func array(elementOID: UInt32, dims: [(Int32, Int32)], elements: [[UInt8]?]) -> [UInt8] {
        var bytes = be(Int32(dims.count)) + be(Int32(elements.contains { $0 == nil } ? 1 : 0)) + be(elementOID)
        for (size, lower) in dims { bytes += be(size) + be(lower) }
        for element in elements {
            if let element { bytes += be(Int32(element.count)) + element } else { bytes += be(Int32(-1)) }
        }
        return bytes
    }

    func testArrays() {
        XCTAssertEqual(format(1007, array(elementOID: 23, dims: [(3, 1)], elements: [be(Int32(1)), be(Int32(2)), nil])), "{1,2,NULL}")
        XCTAssertEqual(format(1009, array(elementOID: 25, dims: [(4, 1)], elements: [
            Array("a b".utf8), Array("".utf8), Array("null".utf8), Array("q\"\\".utf8),
        ])), #"{"a b","","null","q\"\\"}"#)
        XCTAssertEqual(format(1007, array(elementOID: 23, dims: [(2, 1), (2, 1)], elements: [be(Int32(1)), be(Int32(2)), be(Int32(3)), be(Int32(4))])),
                       "{{1,2},{3,4}}")
        XCTAssertEqual(format(1007, array(elementOID: 23, dims: [(2, 0)], elements: [be(Int32(1)), be(Int32(2))])), "[0:1]={1,2}")
        XCTAssertEqual(format(1007, be(Int32(0)) + be(Int32(0)) + be(UInt32(23))), "{}")
    }

    func testArraysOfUnknownTypesAreDetected() {
        // An enum array has a run-time OID; the element OID inside is unknown too.
        let bytes = array(elementOID: 99_001, dims: [(2, 1)], elements: [Array("happy".utf8), Array("sad".utf8)])
        XCTAssertEqual(format(99_000, bytes), "{happy,sad}")
    }

    func testRanges() {
        let lowerInclusive: UInt8 = 0x02
        XCTAssertEqual(format(3904, [lowerInclusive] + be(Int32(4)) + be(Int32(1)) + be(Int32(4)) + be(Int32(10))), "[1,10)")
        XCTAssertEqual(format(3904, [0x01]), "empty")
        let upperOnly: [UInt8] = [UInt8(0x08 | 0x04)] + be(Int32(4)) + be(Int32(5))
        XCTAssertEqual(format(3904, upperOnly), "(,5]")
        XCTAssertEqual(format(3908, [lowerInclusive] + be(Int32(8)) + be(Int64(0)) + be(Int32(8)) + be(Int64(86_400_000_000))),
                       #"["2000-01-01 00:00:00","2000-01-02 00:00:00")"#)
        let range = [lowerInclusive] + be(Int32(4)) + be(Int32(1)) + be(Int32(4)) + be(Int32(3))
        XCTAssertEqual(format(4451, be(Int32(1)) + be(Int32(range.count)) + range), "{[1,3)}")
    }

    func testRecordAndHstore() {
        let record = be(Int32(3)) + be(UInt32(23)) + be(Int32(4)) + be(Int32(7))
            + be(UInt32(25)) + be(Int32(3)) + Array("a,b".utf8)
            + be(UInt32(25)) + be(Int32(-1))
        XCTAssertEqual(format(2249, record), #"(7,"a,b",)"#)
        let hstore = be(Int32(2)) + be(Int32(1)) + Array("a".utf8) + be(Int32(1)) + Array("1".utf8)
            + be(Int32(1)) + Array("b".utf8) + be(Int32(-1))
        XCTAssertEqual(format(98_765, hstore), #""a"=>"1", "b"=>NULL"#)
    }

    func testTextSearch() {
        // 'hello':1 'world':2A
        // Built in steps: one long expression can exceed the type checker's time limit on Linux.
        var vector: [UInt8] = be(Int32(2))
        vector += Array("hello".utf8) + [0]
        vector += be(UInt16(1)) + be(UInt16(1))
        vector += Array("world".utf8) + [0]
        vector += be(UInt16(1)) + be(UInt16(0xC002))
        XCTAssertEqual(format(3614, vector), "'hello':1 'world':2A")
        // 'fat' & ( 'rat' | 'cat' ): prefix order op(&), right subtree first, then left.
        var query: [UInt8] = be(Int32(5))
        query += [2, 2]                                         // &
        query += [2, 3]                                         // |  (right operand of &)
        query += [1, 0, 0] + Array("cat".utf8) + [0]            // right of |
        query += [1, 0, 0] + Array("rat".utf8) + [0]            // left of |
        query += [1, 0, 0] + Array("fat".utf8) + [0]            // left of &
        XCTAssertEqual(format(3615, query), "'fat' & ( 'rat' | 'cat' )")
        let prefix: [UInt8] = be(Int32(1)) + [1, 8, 1] + Array("sup".utf8) + [0]
        XCTAssertEqual(format(3615, prefix), "'sup':*A")
    }

    // MARK: - Fallbacks

    func testUnknownTypesAndMalformedValues() {
        XCTAssertEqual(format(99_999, Array("plain text".utf8)), "plain text")
        XCTAssertEqual(format(99_999, [1] + Array("top.science".utf8)), "top.science") // ltree
        XCTAssertEqual(format(99_999, [0x00, 0x01, 0x02]), "\\x000102")
        XCTAssertEqual(format(23, [1, 2, 3]), "\\x010203", "a truncated int4 is shown as hex, not a wrong number")
    }
}
