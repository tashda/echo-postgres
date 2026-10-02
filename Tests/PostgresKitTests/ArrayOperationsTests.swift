import XCTest
import Logging
@testable import PostgresKit

/// Tests PostgreSQL array operations: reading, operators, functions, and round-trips.
final class ArrayOperationsTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "ArrayOperationsTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() { client?.close(); super.tearDown() }

    private func uniqueName(_ prefix: String = "arr") -> String {
        "\(prefix)_\(UInt32.random(in: 0..<UInt32.max))"
    }

    // MARK: - Read SampleData Arrays

    func testReadIntegerArray() async throws {
        let rows = try await client.simpleQuery("SELECT col_int_arr::text FROM array_types WHERE id = 1")
        var value: String?
        for try await v in rows.decode(String.self) { value = v }
        XCTAssertNotNil(value)
        if let v = value {
            XCTAssertTrue(v.contains("1"), "Should contain integer elements")
        }
    }

    func testReadTextArray() async throws {
        let rows = try await client.simpleQuery("SELECT col_text_arr::text FROM array_types WHERE id = 1")
        var value: String?
        for try await v in rows.decode(String.self) { value = v }
        XCTAssertNotNil(value)
        if let v = value {
            XCTAssertTrue(v.contains("hello") || v.contains("world"), "Should contain text elements")
        }
    }

    func testReadBooleanArray() async throws {
        let rows = try await client.simpleQuery("SELECT col_bool_arr::text FROM array_types WHERE id = 1")
        var value: String?
        for try await v in rows.decode(String.self) { value = v }
        XCTAssertNotNil(value)
        if let v = value {
            XCTAssertTrue(v.contains("t") || v.contains("f"), "Should contain boolean values")
        }
    }

    func testRead2DArray() async throws {
        let rows = try await client.simpleQuery("SELECT col_int_2d::text FROM array_types WHERE id = 1")
        var value: String?
        for try await v in rows.decode(String.self) { value = v }
        XCTAssertNotNil(value, "Should have 2D array")
        if let v = value {
            XCTAssertTrue(v.contains("{"), "2D array should have nested braces")
        }
    }

    func testReadEmptyArrays() async throws {
        let rows = try await client.simpleQuery("SELECT col_int_arr::text, col_text_arr::text FROM array_types WHERE id = 2")
        for try await (intArr, textArr) in rows.decode((String, String).self) {
            XCTAssertEqual(intArr, "{}", "Empty int array should be {}")
            XCTAssertEqual(textArr, "{}", "Empty text array should be {}")
        }
    }

    func testReadSingleElementArrays() async throws {
        let rows = try await client.simpleQuery("SELECT col_int_arr::text FROM array_types WHERE id = 3")
        var value: String?
        for try await v in rows.decode(String.self) { value = v }
        XCTAssertNotNil(value, "Single element array row should exist")
    }

    func testReadNullArrays() async throws {
        let rows = try await client.simpleQuery("SELECT col_int_arr IS NULL AS is_null FROM array_types WHERE id = 4")
        var isNull: Bool?
        for try await v in rows.decode(Bool.self) { isNull = v }
        XCTAssertEqual(isNull, true, "Row 4 should have NULL arrays")
    }

    // MARK: - Array Containment Operators

    func testArrayContainsOperator() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [.serial(name: "id", primaryKey: true), .array(name: "tags", elementType: "TEXT")])
        try await client.bulk.insert(into: table, columns: ["tags"], values: [
            [.array(["swift", "ios", "macos"])],
            [.array(["python", "django"])],
            [.array(["swift", "vapor"])]
        ])

        // @> contains
        let rows = try await client.simpleQuery("SELECT id FROM \(table) WHERE tags @> ARRAY['swift']")
        var count = 0
        for try await _ in rows { count += 1 }
        XCTAssertEqual(count, 2, "Two rows should contain 'swift'")
    }

    func testArrayContainedByOperator() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [.serial(name: "id", primaryKey: true), .array(name: "nums", elementType: "INTEGER")])
        try await client.bulk.insert(into: table, columns: ["nums"], values: [
            [.array([1, 2])],
            [.array([1, 2, 3, 4, 5])],
            [.array([1])]
        ])

        // <@ contained by
        let rows = try await client.simpleQuery("SELECT id FROM \(table) WHERE nums <@ ARRAY[1, 2, 3]")
        var count = 0
        for try await _ in rows { count += 1 }
        XCTAssertEqual(count, 2, "Two rows should be contained by [1,2,3]")
    }

    func testArrayOverlapOperator() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [.serial(name: "id", primaryKey: true), .array(name: "tags", elementType: "TEXT")])
        try await client.bulk.insert(into: table, columns: ["tags"], values: [
            [.array(["a", "b"])],
            [.array(["c", "d"])],
            [.array(["b", "c"])]
        ])

        // && overlap
        let rows = try await client.simpleQuery("SELECT id FROM \(table) WHERE tags && ARRAY['b']")
        var count = 0
        for try await _ in rows { count += 1 }
        XCTAssertEqual(count, 2, "Two rows should overlap with ['b']")
    }

    // MARK: - Array Functions

    func testArrayLength() async throws {
        let rows = try await client.simpleQuery("SELECT array_length(col_int_arr, 1) FROM array_types WHERE id = 1")
        var length: Int?
        for try await l in rows.decode(Int?.self) { length = l }
        XCTAssertNotNil(length)
        XCTAssertGreaterThan(length ?? 0, 0, "Non-empty array should have positive length")
    }

    func testArrayLengthEmpty() async throws {
        // Empty arrays return NULL for array_length
        let rows = try await client.simpleQuery("SELECT array_length(col_int_arr, 1) FROM array_types WHERE id = 2")
        var length: Int?
        for try await l in rows.decode(Int?.self) { length = l }
        XCTAssertNil(length, "Empty array should have NULL length")
    }

    func testUnnest() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [.serial(name: "id", primaryKey: true), .array(name: "nums", elementType: "INTEGER")])
        try await client.bulk.insert(into: table, columns: ["nums"], values: [[.array([10, 20, 30])]])

        let rows = try await client.simpleQuery("SELECT unnest(nums) FROM \(table)")
        var values: [Int64] = []
        for try await v in rows.decode(Int64.self) { values.append(v) }
        XCTAssertEqual(values.sorted(), [10, 20, 30])
    }

    func testArrayAgg() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [.serial(name: "id", primaryKey: true), .text(name: "category"), .integer(name: "value")])
        try await client.bulk.insert(into: table, columns: ["category", "value"], values: [
            ["a", 1],
            ["a", 2],
            ["a", 3],
            ["b", 10],
            ["b", 20]
        ])

        let rows = try await client.simpleQuery("""
            SELECT category, array_agg(value ORDER BY value)::text FROM \(table) GROUP BY category ORDER BY category
        """)
        var results: [(String, String)] = []
        for try await (cat, agg) in rows.decode((String, String).self) {
            results.append((cat, agg))
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].0, "a")
        XCTAssertEqual(results[0].1, "{1,2,3}")
        XCTAssertEqual(results[1].0, "b")
        XCTAssertEqual(results[1].1, "{10,20}")
    }

    // MARK: - Array Concatenation

    func testArrayConcatenation() async throws {
        let rows = try await client.simpleQuery("SELECT (ARRAY[1, 2] || ARRAY[3, 4])::text")
        var result: String?
        for try await v in rows.decode(String.self) { result = v }
        XCTAssertEqual(result, "{1,2,3,4}")
    }

    func testArrayAppendElement() async throws {
        let rows = try await client.simpleQuery("SELECT (ARRAY[1, 2] || 3)::text")
        var result: String?
        for try await v in rows.decode(String.self) { result = v }
        XCTAssertEqual(result, "{1,2,3}")
    }

    func testArrayPrependElement() async throws {
        let rows = try await client.simpleQuery("SELECT (0 || ARRAY[1, 2])::text")
        var result: String?
        for try await v in rows.decode(String.self) { result = v }
        XCTAssertEqual(result, "{0,1,2}")
    }

    // MARK: - Array Element Access

    func testArrayElementAccess() async throws {
        let rows = try await client.simpleQuery("SELECT (ARRAY['a', 'b', 'c'])[2]")
        var result: String?
        for try await v in rows.decode(String.self) { result = v }
        XCTAssertEqual(result, "b", "PostgreSQL arrays are 1-indexed, [2] = 'b'")
    }

    func testArraySlice() async throws {
        let rows = try await client.simpleQuery("SELECT (ARRAY[10, 20, 30, 40, 50])[2:4]::text")
        var result: String?
        for try await v in rows.decode(String.self) { result = v }
        XCTAssertEqual(result, "{20,30,40}")
    }

    // MARK: - Array INSERT and SELECT Round-trip

    func testInsertAndReadIntegerArray() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [.serial(name: "id", primaryKey: true), .array(name: "nums", elementType: "INTEGER")])
        try await client.bulk.insert(into: table, columns: ["nums"], values: [[.array([100, 200, 300])]])

        let rows = try await client.simpleQuery("SELECT nums::text FROM \(table)")
        var result: String?
        for try await v in rows.decode(String.self) { result = v }
        XCTAssertEqual(result, "{100,200,300}")
    }

    func testInsertAndReadTextArray() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [.serial(name: "id", primaryKey: true), .array(name: "words", elementType: "TEXT")])
        try await client.bulk.insert(into: table, columns: ["words"], values: [[.array(["hello", "world", "test"])]])

        let rows = try await client.simpleQuery("SELECT words::text FROM \(table)")
        var result: String?
        for try await v in rows.decode(String.self) { result = v }
        XCTAssertEqual(result, "{hello,world,test}")
    }

    func testInsertAndReadEmptyArray() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [.serial(name: "id", primaryKey: true), .array(name: "items", elementType: "TEXT")])
        try await client.bulk.insert(into: table, columns: ["items"], values: [[.emptyArray(elementType: "TEXT")]])

        let rows = try await client.simpleQuery("SELECT items::text FROM \(table)")
        var result: String?
        for try await v in rows.decode(String.self) { result = v }
        XCTAssertEqual(result, "{}")
    }

    func testInsertAndReadNullArray() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [.serial(name: "id", primaryKey: true), .array(name: "items", elementType: "INTEGER")])
        try await client.bulk.insert(into: table, columns: ["items"], values: [[nil]])

        let rows = try await client.simpleQuery("SELECT items IS NULL AS is_null FROM \(table)")
        var isNull: Bool?
        for try await v in rows.decode(Bool.self) { isNull = v }
        XCTAssertEqual(isNull, true)
    }

    // MARK: - Array with GIN Index

    func testGINIndexOnArrayColumn() async throws {
        let table = uniqueName()
        defer { Task { [client = self.client!] in try? await client.admin.dropTable(name: table, ifExists: true) } }

        try await client.admin.createTable(name: table, columns: [.serial(name: "id", primaryKey: true), .array(name: "tags", elementType: "TEXT")])
        try await client.indexes.createAdvancedIndex(name: "idx_\(table)_tags", table: table, columns: [PostgresIndexColumn(name: "tags")], indexType: .gin)

        // Insert data
        try await client.bulk.insert(into: table, columns: ["tags"], values: [
            [.array(["swift", "ios"])],
            [.array(["python", "django"])],
            [.array(["swift", "vapor"])]
        ])

        // Verify GIN index exists
        let indexRows = try await client.simpleQuery("""
            SELECT indexname FROM pg_indexes WHERE tablename = '\(table)' AND indexdef LIKE '%gin%'
        """)
        var found = false
        for try await _ in indexRows { found = true }
        XCTAssertTrue(found, "GIN index should exist on array column")

        // Query using the index
        let rows = try await client.simpleQuery("SELECT id FROM \(table) WHERE tags @> ARRAY['swift']")
        var count = 0
        for try await _ in rows { count += 1 }
        XCTAssertEqual(count, 2)
    }

    // MARK: - Array Cardinality

    func testArrayCardinality() async throws {
        let rows = try await client.simpleQuery("SELECT cardinality(ARRAY[1, 2, 3, 4, 5])")
        var result: Int64?
        for try await v in rows.decode(Int64.self) { result = v }
        XCTAssertEqual(result, 5)
    }

    func testArrayCardinalityEmpty() async throws {
        let rows = try await client.simpleQuery("SELECT cardinality(ARRAY[]::INTEGER[])")
        var result: Int64?
        for try await v in rows.decode(Int64.self) { result = v }
        XCTAssertEqual(result, 0)
    }

    // MARK: - Array Position and Remove

    func testArrayPosition() async throws {
        let rows = try await client.simpleQuery("SELECT array_position(ARRAY['a', 'b', 'c', 'd'], 'c')")
        var result: Int?
        for try await v in rows.decode(Int.self) { result = v }
        XCTAssertEqual(result, 3, "Position of 'c' should be 3 (1-indexed)")
    }

    func testArrayRemove() async throws {
        let rows = try await client.simpleQuery("SELECT array_remove(ARRAY[1, 2, 3, 2, 1], 2)::text")
        var result: String?
        for try await v in rows.decode(String.self) { result = v }
        XCTAssertEqual(result, "{1,3,1}", "Should remove all occurrences of 2")
    }

    func testArrayReplace() async throws {
        let rows = try await client.simpleQuery("SELECT array_replace(ARRAY[1, 2, 3, 2], 2, 99)::text")
        var result: String?
        for try await v in rows.decode(String.self) { result = v }
        XCTAssertEqual(result, "{1,99,3,99}", "Should replace all 2s with 99")
    }
}
