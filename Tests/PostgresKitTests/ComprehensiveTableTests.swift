import XCTest
import Logging
@testable import PostgresKit

final class ComprehensiveTableTests: PostgresKitTestCase {
    var client: PostgresKit.PostgresClient!
    var testLogger: Logger!

    override func setUp() async throws {
        try await super.setUp()
        testLogger = Logger(label: "postgres.wire.tests")

                guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }

        



        let config = PostgresConfiguration(
            host: TestEnv.host,
            port: TestEnv.port,
            database: TestEnv.database,
            username: TestEnv.username,
            password: TestEnv.password,
            useTLS: TestEnv.useTLS,
            applicationName: "ComprehensiveTableTests"
        )

        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: testLogger)
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    // MARK: - Table Creation with All Data Types

    func testCreateTableWithAllDataTypes() async throws {
        logger.info("Testing Table Creation with All Data Types")

        _ = try await client.admin.dropTable(name: "test_all_types", ifExists: true)

        // Create table with all supported PostgreSQL data types
        do {
            _ = try await client.admin.createTable(
                name: "test_all_types",
                columns: [
                    // Numeric types
                    .bigSerial(name: "id", primaryKey: true),
                    .integer(name: "int_col", nullable: false),
                    .bigInt(name: "bigint_col"),
                    .serial(name: "serial_col"),
                    .bigSerial(name: "bigserial_col"),
                    .decimal(name: "decimal_col", precision: 15, scale: 4),
                    .real(name: "real_col"),
                    .double(name: "double_col"),

                    // Text types
                    .varchar(name: "varchar_col", length: 100),
                    .text(name: "text_col"),
                    .char(name: "char_col", length: 10),

                    // Boolean type
                    .boolean(name: "bool_col", nullable: false, defaultValue: true),

                    // Date/Time types
                    .timestamp(name: "timestamp_col"),
                    .timestampWithTimeZone(name: "timestamptz_col"),
                    .date(name: "date_col"),
                    .time(name: "time_col"),
                    .timeWithTimeZone(name: "timetz_col"),

                    // JSON types
                    .json(name: "json_col"),
                    .jsonb(name: "jsonb_col"),

                    // Binary type
                    .bytea(name: "bytea_col"),

                    // UUID type
                    .uuid(name: "uuid_col", nullable: false),

                    // Array types
                    .array(name: "int_array_col", elementType: "INTEGER"),
                    .array(name: "text_array_col", elementType: "TEXT"),

                    // Network types
                    .inet(name: "inet_col"),
                    .cidr(name: "cidr_col"),
                    .macaddr(name: "macaddr_col"),

                    // Custom enum type (simulate with text)
                    .varchar(name: "status_col", length: 20, nullable: false, defaultValue: "active")
                ]
            )
            logger.info("Table creation successful")
        } catch {
            logger.error("Table creation failed: \(error)")
            throw error
        }

        // Verify table was created successfully by checking table existence
        do {
            let result = try await client.simpleQuery("""
                SELECT EXISTS (
                    SELECT FROM information_schema.tables
                    WHERE table_name = 'test_all_types'
                );
                """)
            var tableExists = false
            for try await (exists) in result.decode((Bool).self) {
                tableExists = exists
                break
            }
            XCTAssertTrue(tableExists, "Table should exist and be queryable")
            if tableExists {
                logger.info("Table verification successful")
            } else {
                logger.error("Table verification failed - table does not exist")
            }
        } catch {
            logger.error("Table verification failed: \(error)")
            XCTFail("Table verification failed with error: \(error)")
        }

        // Cleanup
        _ = try await client.admin.dropTable(name: "test_all_types", ifExists: false)

        logger.info("Table creation with all data types test passed")
    }

    // MARK: - Table Operations with Complex Data Types

    func testTableOperationsWithComplexDataTypes() async throws {
        logger.info("Testing Table Operations with Complex Data Types")

        _ = try await client.admin.dropTable(name: "test_complex_table", ifExists: true)

        // Create table with complex data types
        _ = try await client.admin.createTable(
            name: "test_complex_table",
            columns: [
                .bigSerial(name: "id", primaryKey: true),
                .varchar(name: "name", length: 100, nullable: false),
                .jsonb(name: "metadata", nullable: false),
                .array(name: "tags", elementType: "TEXT"),
                .uuid(name: "external_id"),
                .bytea(name: "binary_data"),
                .text(name: "description")
            ]
        )

        _ = try await client.bulk.insert(
            into: "test_complex_table",
            columns: ["name", "metadata", "tags", "external_id", "binary_data", "description"],
            values: [
                [
                    "Product One",
                    .jsonbLiteral("{\"category\": \"electronics\", \"price\": 999.99, \"features\": [\"wifi\", \"bluetooth\"]}"),
                    .array(["new", "featured", "electronics"]),
                    PostgresInsertValue(UUID(uuidString: "550e8400-e29b-41d4-a716-446655440001")!),
                    PostgresInsertValue(Data("binary data content here".utf8)),
                    "High-end electronic product"
                ],
                [
                    "Product Two",
                    .jsonbLiteral("{\"category\": \"books\", \"price\": 29.99, \"pages\": 300}"),
                    .array(["books", "fiction", "bestseller"]),
                    PostgresInsertValue(UUID(uuidString: "550e8400-e29b-41d4-a716-446655440002")!),
                    PostgresInsertValue(Data("more binary content".utf8)),
                    "Bestselling fiction book"
                ]
            ]
        )

        // Test JSONB queries
        let jsonResult = try await client.simpleQuery("SELECT name, metadata->>'category' as category FROM test_complex_table WHERE metadata @> '{\"category\": \"electronics\"}'")
        var electronicsCount = 0
        for try await (name, category) in jsonResult.decode((String, String).self) {
            electronicsCount += 1
            logger.info("Found electronics product: \(name) - \(category)")
        }
        XCTAssertEqual(electronicsCount, 1, "Should find one electronics product")

        // Test array queries
        let arrayResult = try await client.simpleQuery("SELECT name, tags FROM test_complex_table WHERE tags @> ARRAY['books']")
        var booksCount = 0
        for try await (name, tags) in arrayResult.decode((String, [String]).self) {
            booksCount += 1
            logger.info("Found book product: \(name) - tags: \(tags)")
        }
        XCTAssertEqual(booksCount, 1, "Should find one book product")

        // Test UUID queries
        let uuidResult = try await client.simpleQuery("SELECT name FROM test_complex_table WHERE external_id = '550e8400-e29b-41d4-a716-446655440001'")
        var foundUUID = false
        for try await name in uuidResult.decode(String?.self) {
            if let name = name {
                XCTAssertEqual(name, "Product One")
                foundUUID = true
                break
            }
        }
        XCTAssertTrue(foundUUID, "Should find product by UUID")

        // Cleanup
        _ = try await client.admin.dropTable(name: "test_complex_table", ifExists: false)

        logger.info("Table operations with complex data types test passed")
    }

    // MARK: - Table Alter Operations

    func testAlterTableOperations() async throws {
        logger.info("Testing Alter Table Operations")

        _ = try await client.admin.dropTable(name: "test_alter_table", ifExists: true)

        // Create initial table
        _ = try await client.admin.createTable(
            name: "test_alter_table",
            columns: [
                .bigSerial(name: "id", primaryKey: true),
                .varchar(name: "name", length: 50, nullable: false),
                .integer(name: "value", nullable: false)
            ]
        )

        // Insert initial data
        _ = try await client.bulk.insert(
            into: "test_alter_table",
            columns: ["name", "value"],
            values: [["Item 1", 100], ["Item 2", 200]]
        )

        // Test adding columns with different data types
        _ = try await client.admin.addColumn(table: "test_alter_table", column: .text(name: "description"))
        _ = try await client.admin.addColumn(table: "test_alter_table", column: .timestamp(name: "created_at", defaultValue: "CURRENT_TIMESTAMP"))
        _ = try await client.admin.addColumn(table: "test_alter_table", column: .boolean(name: "is_active", defaultValue: true))
        _ = try await client.admin.addColumn(table: "test_alter_table", column: .decimal(name: "price", precision: 10, scale: 2))
        _ = try await client.admin.addColumn(table: "test_alter_table", column: .array(name: "tags", elementType: "TEXT"))
        _ = try await client.admin.addColumn(table: "test_alter_table", column: .jsonb(name: "metadata"))
        _ = try await client.admin.addColumn(table: "test_alter_table", column: .uuid(name: "external_id"))

        _ = try await client.bulk.insert(
            into: "test_alter_table",
            columns: ["name", "value", "description", "price", "tags", "metadata", "external_id"],
            values: [
                ["Item 3", 300, "Third item", 39.99, .array(["new", "featured"]), .jsonbLiteral("{\"priority\": \"high\"}"), PostgresInsertValue(UUID(uuidString: "550e8400-e29b-41d4-a716-446655440003")!)],
                ["Item 4", 400, "Fourth item", 49.99, .array(["sale", "discount"]), .jsonbLiteral("{\"discount\": true}"), PostgresInsertValue(UUID(uuidString: "550e8400-e29b-41d4-a716-446655440004")!)]
            ]
        )

        // Verify new columns exist and have correct data - simple validation
        let countResult = try await client.simpleQuery("SELECT COUNT(*) FROM test_alter_table WHERE description IS NOT NULL")
        var itemCount = 0
        for try await rowCount in countResult.decode((Int64?).self) {
            if let rowCount = rowCount {
                itemCount = Int(rowCount)
                break
            }
        }
        XCTAssertEqual(itemCount, 2, "Should find 2 items with descriptions")

        // Test modifying column types
        _ = try await client.admin.alterColumnType(table: "test_alter_table", column: "value", newType: "BIGINT")
        _ = try await client.admin.alterColumnType(table: "test_alter_table", column: "name", newType: "VARCHAR(100)")

        // Test adding constraints
        _ = try await client.constraints.addCheckConstraint(
            table: "test_alter_table",
            condition: "price > 0",
            constraintName: "ck_price_positive"
        )

        _ = try await client.constraints.addUniqueConstraint(
            table: "test_alter_table",
            columns: ["external_id"],
            constraintName: "uk_external_id"
        )

        // Test adding and dropping columns
        _ = try await client.admin.addColumn(table: "test_alter_table", column: .text(name: "dummy_column"))
        _ = try await client.admin.dropColumn(table: "test_alter_table", column: "dummy_column")

        // Cleanup
        _ = try await client.admin.dropTable(name: "test_alter_table", ifExists: false)

        logger.info("Alter table operations test passed")
    }
}
