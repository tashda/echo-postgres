import XCTest
@testable import PostgresWire

final class PostgresFormatterEngineTests: XCTestCase {

    // MARK: - Helpers

    private func cell(oid: UInt32, bytes: Data?, format: ResultCellPayload.Format = .binary) -> ResultCellPayload {
        ResultCellPayload(dataTypeOID: oid, format: format, bytes: bytes)
    }

    private func singleCellRow(_ cell: ResultCellPayload) -> ResultRowPayload {
        ResultRowPayload(cells: [cell], rowIndex: 0)
    }

    private func makeEngine(configure: ((inout PostgresStreamConfiguration) -> Void)? = nil) -> PostgresFormatterEngine {
        var config = PostgresStreamConfiguration()
        configure?(&config)
        return PostgresFormatterEngine(configuration: config)
    }

    // MARK: - Null handling

    func testNilBytes_ReturnsNullDisplay() async {
        let engine = makeEngine()
        let payload = singleCellRow(cell(oid: 25, bytes: nil))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result, ["NULL"])
    }

    func testEmptyText_IsEmptyStringNotNull() async {
        let engine = makeEngine()
        let payload = singleCellRow(cell(oid: 25, bytes: Data()))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result, [""])
    }

    func testCustomNullDisplay() async {
        let engine = makeEngine { $0.nullValueDisplay = "<NULL>" }
        let payload = singleCellRow(cell(oid: 25, bytes: nil))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result, ["<NULL>"])
    }

    func testCustomNullDisplay_OnlyForNull() async {
        let engine = makeEngine { $0.nullValueDisplay = "—" }
        let payload = singleCellRow(cell(oid: 25, bytes: Data()))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result, [""])
    }

    // MARK: - Boolean formatting (OID 16)

    func testBoolean_NonZero_ReturnsTrue() async {
        let engine = makeEngine()
        let payload = singleCellRow(cell(oid: 16, bytes: Data([1])))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result, ["true"])
    }

    func testBoolean_Zero_ReturnsFalse() async {
        let engine = makeEngine()
        let payload = singleCellRow(cell(oid: 16, bytes: Data([0])))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result, ["false"])
    }

    func testBoolean_MaxByte_ReturnsTrue() async {
        let engine = makeEngine()
        let payload = singleCellRow(cell(oid: 16, bytes: Data([255])))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result, ["true"])
    }

    func testBoolean_CustomTrueDisplay() async {
        let engine = makeEngine { $0.booleanTrueDisplay = "YES" }
        let payload = singleCellRow(cell(oid: 16, bytes: Data([1])))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result, ["YES"])
    }

    func testBoolean_CustomFalseDisplay() async {
        let engine = makeEngine { $0.booleanFalseDisplay = "NO" }
        let payload = singleCellRow(cell(oid: 16, bytes: Data([0])))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result, ["NO"])
    }

    func testBoolean_WrongSize_FallsBackToBase64() async {
        let engine = makeEngine()
        // More than 1 byte falls back to base64
        let data = Data([1, 0])
        let payload = singleCellRow(cell(oid: 16, bytes: data))
        let result = await engine.formatRow(payload)
        // Should be base64 encoded (not "true"/"false")
        XCTAssertNotEqual(result[0], "true")
        XCTAssertNotEqual(result[0], "false")
    }

    // MARK: - Text formatting (OID 25, 1043, 18)

    func testText_ReturnsUTF8String() async {
        let engine = makeEngine()
        let data = "Hello, World!".data(using: .utf8)!
        let payload = singleCellRow(cell(oid: 25, bytes: data))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result, ["Hello, World!"])
    }

    func testVarchar_ReturnsUTF8String() async {
        let engine = makeEngine()
        let data = "test string".data(using: .utf8)!
        let payload = singleCellRow(cell(oid: 1043, bytes: data))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result, ["test string"])
    }

    func testUnicodeText() async {
        let engine = makeEngine()
        let text = "Héllo Wörld 🌍"
        let data = text.data(using: .utf8)!
        let payload = singleCellRow(cell(oid: 25, bytes: data))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result, [text])
    }

    // MARK: - Integer formatting (OID 21, 23, 20)

    func testSmallInt_TwoBytes_ProducesNumericString() async {
        let engine = makeEngine()
        let value: Int16 = 100
        let data = withUnsafeBytes(of: value.bigEndian) { Data($0) }
        let payload = singleCellRow(cell(oid: 21, bytes: data))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result[0], "100")
    }

    func testInteger_FourBytes_ProducesNumericString() async {
        let engine = makeEngine()
        let value: Int32 = 42
        let data = withUnsafeBytes(of: value.bigEndian) { Data($0) }
        let payload = singleCellRow(cell(oid: 23, bytes: data))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result[0], "42")
    }

    func testBigInt_EightBytes_ProducesNumericString() async {
        let engine = makeEngine()
        let value: Int64 = 1_000_000
        let data = withUnsafeBytes(of: value.bigEndian) { Data($0) }
        let payload = singleCellRow(cell(oid: 20, bytes: data))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result[0], "1000000")
    }

    func testInteger_WrongSize_ShowsHex() async {
        let engine = makeEngine()
        // 3 bytes doesn't match int4: shown as raw hex rather than a wrong number or NULL
        let payload = singleCellRow(cell(oid: 23, bytes: Data([1, 2, 3])))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result, ["\\x010203"])
    }

    // MARK: - UUID formatting (OID 2950)

    func testUUID_SixteenBytes_ProducesUUIDString() async {
        let engine = makeEngine()
        let uuid = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        let data = withUnsafeBytes(of: uuid.uuid) { Data($0) }
        let payload = singleCellRow(cell(oid: 2950, bytes: data))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result[0], "550e8400-e29b-41d4-a716-446655440000")
    }

    func testUUID_WrongSize_FallsBackToBase64() async {
        let engine = makeEngine()
        let data = Data([1, 2, 3]) // wrong size
        let payload = singleCellRow(cell(oid: 2950, bytes: data))
        let result = await engine.formatRow(payload)
        XCTAssertNotNil(result[0])
        XCTAssertNil(UUID(uuidString: result[0]!))
    }

    // MARK: - Bytea formatting (OID 17)

    func testBytea_ProducesHexString() async {
        let engine = makeEngine()
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let payload = singleCellRow(cell(oid: 17, bytes: data))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result[0], "\\xdeadbeef")
    }

    func testBytea_SingleByte() async {
        let engine = makeEngine()
        let data = Data([0x0F])
        let payload = singleCellRow(cell(oid: 17, bytes: data))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result[0], "\\x0f")
    }

    func testBytea_AllZeros() async {
        let engine = makeEngine()
        let data = Data([0x00, 0x00])
        let payload = singleCellRow(cell(oid: 17, bytes: data))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result[0], "\\x0000")
    }

    // MARK: - JSON formatting (OID 114, 3802)

    func testJSON_ValidJSON_ProducesString() async {
        let engine = makeEngine()
        let json = #"{"key":"value"}"#
        let data = json.data(using: .utf8)!
        let payload = singleCellRow(cell(oid: 114, bytes: data))
        let result = await engine.formatRow(payload)
        XCTAssertNotNil(result[0])
        XCTAssertTrue(result[0]!.contains("key"))
    }

    func testJSONB_ValidJSON_ProducesString() async {
        let engine = makeEngine()
        let json = #"{"number":42}"#
        let data = Data([1]) + json.data(using: .utf8)! // jsonb binary format starts with version 1
        let payload = singleCellRow(cell(oid: 3802, bytes: data))
        let result = await engine.formatRow(payload)
        XCTAssertNotNil(result[0])
        XCTAssertTrue(result[0]!.contains("42"))
    }

    // MARK: - Unknown/fallback type

    func testUnknownOID_UTF8Fallback() async {
        let engine = makeEngine()
        let data = "some value".data(using: .utf8)!
        let payload = singleCellRow(cell(oid: 99999, bytes: data))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result[0], "some value")
    }

    // MARK: - Multiple cells in a row

    func testMultipleCells_MixedTypes() async {
        let engine = makeEngine()
        let cells = [
            cell(oid: 25, bytes: "Alice".data(using: .utf8)!),   // text
            cell(oid: 16, bytes: Data([1])),                      // boolean true
            cell(oid: 25, bytes: nil)                             // null
        ]
        let payload = ResultRowPayload(cells: cells, rowIndex: 0)
        let result = await engine.formatRow(payload)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], "Alice")
        XCTAssertEqual(result[1], "true")
        XCTAssertEqual(result[2], "NULL")
    }

    func testEmptyRow_ReturnsEmptyArray() async {
        let engine = makeEngine()
        let payload = ResultRowPayload(cells: [], rowIndex: 0)
        let result = await engine.formatRow(payload)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - setColumns does not crash

    func testSetColumns_DoesNotCrash() async {
        let engine = makeEngine()
        let columns = [
            ColumnInfo(name: "id", dataType: "int4"),
            ColumnInfo(name: "name", dataType: "text")
        ]
        await engine.setColumns(columns)
        // After setting columns, formatting should still work
        let payload = singleCellRow(cell(oid: 25, bytes: "test".data(using: .utf8)!))
        let result = await engine.formatRow(payload)
        XCTAssertEqual(result, ["test"])
    }
}
