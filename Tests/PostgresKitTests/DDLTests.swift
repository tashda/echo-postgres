import XCTest
import Logging
@testable import PostgresKit

final class DDLTests: PostgresKitTestCase {

    private var client: PostgresKit.PostgresClient!
    private var testLogger: Logger!

    override func setUp() async throws {
        try await super.setUp()
        testLogger = Logger(label: "postgres.wire.tests")

        // Check if required environment variables are set
                guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        

        let config = PostgresConfiguration(
            host: TestEnv.host,
            port: TestEnv.port,
            database: TestEnv.database,
            username: TestEnv.username,
            password: TestEnv.password,
            useTLS: TestEnv.useTLS,
            applicationName: "DDLTests"
        )

        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: testLogger)
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    // MARK: - Table Creation Tests

    func testCreateTableWithAllDataTypes() async throws {
        logger.info("Testing CREATE TABLE with all data types")

        // Drop table if it exists
        _ = try await client.admin.dropTable(name: "all_types_test", ifExists: true)

        // Create table using PostgresClient API
        _ = try await client.admin.createTable(
            name: "all_types_test",
            columns: [
                .serial(name: "id", primaryKey: true),
                .text(name: "text_col"),
                .varchar(name: "varchar_col", length: 255),
                .char(name: "char_col", length: 10),
                .integer(name: "integer_col"),
                .bigInt(name: "bigint_col"),
                .integer(name: "smallint_col"), // Using integer for SMALLINT
                .decimal(name: "decimal_col", precision: 10, scale: 2),
                .decimal(name: "numeric_col", precision: 15, scale: 5),
                .real(name: "real_col"),
                .double(name: "double_col"),
                .boolean(name: "boolean_col"),
                .date(name: "date_col"),
                .time(name: "time_col"),
                .timestamp(name: "timestamp_col"),
                .timestampWithTimeZone(name: "timestamptz_col"),
                .uuid(name: "uuid_col"),
                .json(name: "json_col"),
                .jsonb(name: "jsonb_col"),
                .bytea(name: "bytea_col"),
                .text(name: "point_col"), // Using text for geometric types
                .text(name: "box_col"),
                .text(name: "path_col"),
                .text(name: "polygon_col"),
                .text(name: "line_col"),
                .text(name: "circle_col"),
                .cidr(name: "cidr_col"),
                .inet(name: "inet_col"),
                .macaddr(name: "macaddr_col"),
                .text(name: "tsvector_col"), // Using text for TSVECTOR
                .text(name: "tsquery_col"), // Using text for TSQUERY
                .array(name: "array_col", elementType: "INTEGER"),
                .timestamp(name: "created_at")
            ]
        )

        // Verify table was created successfully by querying it
        let result = try await client.simpleQuery("""
            SELECT column_name, data_type, character_maximum_length
            FROM information_schema.columns
            WHERE table_name = 'all_types_test'
            ORDER BY ordinal_position
        """)

        var columnCount = 0
        for try await (name, dataType, maxLength) in result.decode((String, String, Int?).self) {
            logger.info("Column: \(name), Type: \(dataType), Max Length: \(maxLength ?? -1)")
            columnCount += 1
        }

        // Should have at least 25+ columns
        XCTAssertGreaterThan(columnCount, 25)
        logger.info("Successfully created table with \(columnCount) columns")

        // Test data insertion using API with raw SQL for complex types
        let testUUID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!

        _ = try await client.bulk.insert(
            into: "all_types_test",
            columns: ["text_col", "varchar_col", "integer_col", "bigint_col", "boolean_col", "uuid_col", "jsonb_col", "array_col"],
            values: [[
                "Test text",
                "Test varchar",
                42,
                999_999_999,
                true,
                PostgresInsertValue(testUUID),
                .jsonbLiteral("{\"key\": \"value\"}"),
                .array([1, 2, 3])
            ]]
        )

        logger.info("Successfully inserted test data into all types table")
    }

    func testCreateTableWithConstraints() async throws {
        logger.info("Testing CREATE TABLE with constraints")

        // Clean up existing tables
        _ = try await client.admin.dropTable(name: "employees", ifExists: true)
        _ = try await client.admin.dropTable(name: "departments", ifExists: true)

        // Create referenced table using PostgresClient API
        _ = try await client.admin.createTable(
            name: "departments",
            columns: [
                .serial(name: "id", primaryKey: true),
                .varchar(name: "name", length: 100, nullable: false),
                .varchar(name: "code", length: 10, nullable: false)
            ]
        )

        // Add unique constraint to departments table
        _ = try await client.constraints.addUniqueConstraint(
            table: "departments",
            columns: ["name"],
            constraintName: "uk_departments_name"
        )

        // Insert test data using PostgresClient API
        _ = try await client.bulk.insert(
            into: "departments",
            columns: ["name", "code"],
            values: [["Engineering", "ENG"], ["Sales", "SLS"]]
        )

        // Create table with various constraints using PostgresClient API
        _ = try await client.admin.createTable(
            name: "employees",
            columns: [
                .serial(name: "id", primaryKey: true),
                .varchar(name: "first_name", length: 50, nullable: false),
                .varchar(name: "last_name", length: 50, nullable: false),
                .varchar(name: "email", length: 100, nullable: false),
                .integer(name: "age"),
                .decimal(name: "salary", precision: 10, scale: 2),
                .integer(name: "department_id"),
                .date(name: "hire_date"),
                .boolean(name: "is_active", defaultValue: true),
                .timestamp(name: "created_at")
            ]
        )

        // Add constraints using PostgresClient API
        _ = try await client.constraints.addUniqueConstraint(
            table: "employees",
            columns: ["email"],
            constraintName: "uk_employees_email"
        )

        _ = try await client.constraints.addCheckConstraint(
            table: "employees",
            condition: "age >= 18 AND age <= 100",
            constraintName: "ck_employees_age"
        )

        _ = try await client.constraints.addCheckConstraint(
            table: "employees",
            condition: "email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$'",
            constraintName: "ck_employees_email_format"
        )

        _ = try await client.constraints.addForeignKey(
            table: "employees",
            column: "department_id",
            referencesTable: "departments",
            referencesColumn: "id",
            constraintName: "fk_employees_department"
        )

            // Test constraint violations using PostgresClient API
        do {
            _ = try await client.bulk.insert(
                into: "employees",
                columns: ["first_name", "last_name", "email", "age"],
                values: [["John", "Doe", "invalid-email", 25]]
            )
            XCTFail("Should have failed with email constraint violation")
        } catch {
            logger.info("Email constraint violation caught: \(error.localizedDescription)")
        }

        do {
            _ = try await client.bulk.insert(
                into: "employees",
                columns: ["first_name", "last_name", "email", "age"],
                values: [["Jane", "Doe", "jane@example.com", 15]]
            )
            XCTFail("Should have failed with age check constraint violation")
        } catch {
            logger.info("Age constraint violation caught: \(error.localizedDescription)")
        }

        // Test valid insert
        _ = try await client.bulk.insert(
            into: "employees",
            columns: ["first_name", "last_name", "email", "age", "department_id"],
            values: [["John", "Doe", "john@example.com", 30, 1]]
        )

        // Test unique constraint
        do {
            _ = try await client.bulk.insert(
                into: "employees",
                columns: ["first_name", "last_name", "email", "age"],
                values: [["John", "Smith", "john@example.com", 35]]
            )
            XCTFail("Should have failed with unique constraint violation")
        } catch {
            logger.info("Unique constraint violation caught: \(error.localizedDescription)")
        }

        // Count employees using PostgresClient API
        let countRows = try await client.simpleQuery("SELECT COUNT(*)::text FROM employees")
        var count = 0
        for try await countStr in countRows.decode(String.self) {
            if let intVal = Int(countStr) {
                count = intVal
            }
            break
        }

        XCTAssertEqual(count, 1)
        logger.info("All constraint tests passed")
    }

    // MARK: - Table Alteration Tests

    func testAlterTable() async throws {
        logger.info("Testing ALTER TABLE operations")

        // Clean up existing table
        _ = try await client.admin.dropTable(name: "alter_test", ifExists: true)

        // Create initial table
        _ = try await client.admin.createTable(
            name: "alter_test",
            columns: [
                .serial(name: "id", primaryKey: true),
                .varchar(name: "name", length: 50)
            ]
        )

        // Test ADD COLUMN
        _ = try await client.admin.addColumn(table: "alter_test", column: .integer(name: "age"))
        _ = try await client.admin.addColumn(table: "alter_test", column: .varchar(name: "email", length: 100))

        // Test ALTER COLUMN TYPE
        _ = try await client.admin.alterColumnType(table: "alter_test", column: "name", newType: "VARCHAR(100)")

        // Test SET DEFAULT
        _ = try await client.admin.alterColumnDefault(table: "alter_test", column: "age", defaultValue: "25")

        // Test SET NOT NULL (need to update existing nulls first)
        _ = try await client.admin.alterColumnNullability(table: "alter_test", column: "age", nullable: false)

        // Test DROP COLUMN
        _ = try await client.admin.dropColumn(table: "alter_test", column: "email")

        // Test ADD CONSTRAINT
        _ = try await client.constraints.addCheckConstraint(table: "alter_test", condition: "length(name) > 2", constraintName: "check_name")

        // Test RENAME COLUMN
        _ = try await client.admin.renameColumn(table: "alter_test", oldName: "name", newName: "full_name")

        // Insert test data
        _ = try await client.bulk.insert(
            into: "alter_test",
            columns: ["full_name"],
            values: [["John Doe"]]
        )

        // Verify the data uses the default age
        let rows = try await client.simpleQuery("SELECT id, full_name, age FROM alter_test")
        var results: [(Int32, String, Int32)] = []
        for try await (id, name, age) in rows.decode((Int32, String, Int32).self) {
            results.append((id, name, age))
        }

        let result = results.first?.2 ?? 0
        XCTAssertEqual(result, 25) // Should use the default age
        logger.info("ALTER TABLE operations completed successfully")
    }

    // MARK: - Index Tests

    func testCreateAndDropIndexes() async throws {
        logger.info("Testing Index operations")

        // Clean up existing table
        _ = try await client.admin.dropTable(name: "index_test", ifExists: true)

        // Create table using PostgresClient API
        _ = try await client.admin.createTable(
            name: "index_test",
            columns: [
                .serial(name: "id", primaryKey: true),
                .varchar(name: "name", length: 100),
                .varchar(name: "email", length: 100),
                .integer(name: "age"),
                .timestamp(name: "created_at", defaultValue: "CURRENT_TIMESTAMP")
            ]
        )

        // Insert test data using PostgresClient API
        var testData: [[Any]] = []
        for i in 1...100 {
            testData.append([
                "User \(i)",
                "user\(i)@example.com",
                20 + (i % 50)
            ])
        }

        _ = try await client.bulk.insert(
            into: "index_test",
            columns: ["name", "email", "age"],
            values: testData
        )

        // Test CREATE INDEX using PostgresClient API
        _ = try await client.indexes.createIndex(
            name: "idx_index_test_name",
            table: "index_test",
            columns: ["name"],
            unique: false
        )

        _ = try await client.indexes.createIndex(
            name: "idx_index_test_email",
            table: "index_test",
            columns: ["email"],
            unique: false
        )

        _ = try await client.indexes.createIndex(
            name: "idx_index_test_age",
            table: "index_test",
            columns: ["age"],
            unique: false
        )

        // Test CREATE UNIQUE INDEX using PostgresClient API
        _ = try await client.indexes.createIndex(
            name: "idx_index_test_unique_name",
            table: "index_test",
            columns: ["name"],
            unique: true
        )

        // Test composite index using PostgresClient API
        _ = try await client.indexes.createIndex(
            name: "idx_index_test_composite",
            table: "index_test",
            columns: ["name", "age"],
            unique: false
        )

        // Verify indexes exist using PostgresClient API
        let indexRows = try await client.simpleQuery("""
            SELECT indexname, indexdef
            FROM pg_indexes
            WHERE tablename = 'index_test'
            ORDER BY indexname
        """)

        var indexCount = 0
        for try await (indexName, indexDef) in indexRows.decode((String, String).self) {
            logger.info("Index: \(indexName) - \(indexDef)")
            indexCount += 1
        }

        // Test index usage with EXPLAIN using PostgresClient API
        let explainPlan = try await client.executionPlan.explain("SELECT * FROM index_test WHERE name = 'User 42'", format: .json)
        for plan in explainPlan {
            logger.info("Query plan: \(plan)")
        }

        // Test DROP INDEX using PostgresClient API
        _ = try await client.indexes.dropIndex(name: "idx_index_test_name", ifExists: false)
        _ = try await client.indexes.dropIndex(name: "idx_index_test_email", ifExists: false)
        _ = try await client.indexes.dropIndex(name: "idx_index_test_age", ifExists: false)
        _ = try await client.indexes.dropIndex(name: "idx_index_test_unique_name", ifExists: false)
        _ = try await client.indexes.dropIndex(name: "idx_index_test_composite", ifExists: false)

        XCTAssertGreaterThan(indexCount, 4) // Should have created at least 4 indexes
        logger.info("Index operations completed successfully")
    }

    // MARK: - Foreign Key Tests

    func testForeignKeys() async throws {
        logger.info("Testing Foreign Key operations")

        // Clean up existing tables (order matters for foreign keys)
        _ = try await client.admin.dropTable(name: "books", ifExists: true, cascade: true)
        _ = try await client.admin.dropTable(name: "authors", ifExists: true, cascade: true)
        _ = try await client.admin.dropTable(name: "publishers", ifExists: true, cascade: true)

        // Create parent tables
        _ = try await client.admin.createTable(
            name: "authors",
            columns: [
                .serial(name: "id", primaryKey: true),
                .varchar(name: "name", length: 100, nullable: false),
                .varchar(name: "email", length: 100)
            ]
        )
        _ = try await client.constraints.addUniqueConstraint(
            table: "authors",
            columns: ["email"],
            constraintName: "uk_authors_email"
        )

        _ = try await client.admin.createTable(
            name: "publishers",
            columns: [
                .serial(name: "id", primaryKey: true),
                .varchar(name: "name", length: 100, nullable: false)
            ]
        )

        // Create child table with foreign keys
        _ = try await client.admin.createTable(
            name: "books",
            columns: [
                .serial(name: "id", primaryKey: true),
                .varchar(name: "title", length: 200, nullable: false),
                .integer(name: "author_id"),
                .integer(name: "publisher_id"),
                .varchar(name: "isbn", length: 20),
                .date(name: "published_date")
            ]
        )

        _ = try await client.constraints.addForeignKey(
            table: "books",
            column: "author_id",
            referencesTable: "authors",
            referencesColumn: "id",
            constraintName: "fk_books_author",
            onDelete: .cascade
        )

        _ = try await client.constraints.addForeignKey(
            table: "books",
            column: "publisher_id",
            referencesTable: "publishers",
            referencesColumn: "id",
            constraintName: "fk_books_publisher",
            onDelete: .setNull
        )

        _ = try await client.constraints.addUniqueConstraint(
            table: "books",
            columns: ["isbn"],
            constraintName: "uk_books_isbn"
        )

        // Set NOT NULL on author_id after adding the foreign key
        _ = try await client.admin.alterColumnNullability(table: "books", column: "author_id", nullable: false)

        // Insert test data
        _ = try await client.bulk.insert(
            into: "authors",
            columns: ["name", "email"],
            values: [
                ["J.K. Rowling", "jk@rowling.com"],
                ["Stephen King", "stephen@king.com"]
            ]
        )

        _ = try await client.bulk.insert(
            into: "publishers",
            columns: ["name"],
            values: [["Bloomsbury"], ["Penguin Books"]]
        )

        _ = try await client.bulk.insert(
            into: "books",
            columns: ["title", "author_id", "publisher_id", "isbn", "published_date"],
            values: [
                ["Harry Potter 1", 1, 1, "978-0-7475-3268-9", .date("1997-06-26")],
                ["The Shining", 2, 2, "978-0-385-12167-5", .date("1977-01-28")]
            ]
        )

        // Test foreign key constraint violation
        do {
            _ = try await client.bulk.insert(
                into: "books",
                columns: ["title", "author_id", "publisher_id", "isbn"],
                values: [["Invalid Book", 999, 1, "invalid-isbn"]]
            )
            XCTFail("Should have failed with foreign key violation")
        } catch {
            logger.info("Foreign key constraint violation caught: \(error)")
        }

        // Verify initial state
        let initialCountRows = try await client.simpleQuery("SELECT COUNT(*)::text FROM books")
        var initialCount = 0
        for try await countStr in initialCountRows.decode(String.self) {
            if let intVal = Int(countStr) {
                initialCount = intVal
            }
            break
        }
        logger.info("Initial books count: \(initialCount)")

        // Count books before delete operations
        let beforeCountRows = try await client.simpleQuery("SELECT COUNT(*)::text FROM books")
        var beforeCount = 0
        for try await countStr in beforeCountRows.decode(String.self) {
            if let intVal = Int(countStr) {
                beforeCount = intVal
            }
            break
        }

        // Test CASCADE delete
        _ = try await client.bulk.delete(from: "authors", whereClause: "id = 1")

        // Test SET NULL delete
        _ = try await client.bulk.delete(from: "publishers", whereClause: "id = 2")

        // Count remaining books after both operations
        let afterCountRows = try await client.simpleQuery("SELECT COUNT(*)::text FROM books")
        var afterCount = 0
        for try await countStr in afterCountRows.decode(String.self) {
            if let intVal = Int(countStr) {
                afterCount = intVal
            }
            break
        }

        let affectedCount = beforeCount - afterCount
        logger.info("Books before: \(beforeCount), after: \(afterCount), affected: \(affectedCount)")

        XCTAssertEqual(affectedCount, 1) // 1 book deleted via CASCADE
        logger.info("Foreign key operations completed successfully - affected \(affectedCount) records")
        logger.info("Foreign key operations completed successfully")
    }

    // MARK: - Drop Table Tests

    func testDropTable() async throws {
        logger.info("Testing DROP TABLE operations")

        // Clean up existing table
        _ = try await client.admin.dropTable(name: "drop_test", ifExists: true)

        // Create table
        _ = try await client.admin.createTable(
            name: "drop_test",
            columns: [
                .serial(name: "id", primaryKey: true),
                .varchar(name: "name", length: 50)
            ]
        )

        // Insert data
        _ = try await client.bulk.insert(
            into: "drop_test",
            columns: ["name"],
            values: [["Test"]]
        )

        // Verify table exists
        let beforeCount = try await client.simpleQuery("SELECT COUNT(*)::text FROM drop_test")
        var before = 0
        for try await countStr in beforeCount.decode(String.self) {
            if let intVal = Int(countStr) {
                before = intVal
            }
            break
        }

        // Drop table
        _ = try await client.admin.dropTable(name: "drop_test")

        // Try to query dropped table (should fail)
        do {
            _ = try await client.simpleQuery("SELECT COUNT(*)::text FROM drop_test")
            XCTFail("Should have failed - table should not exist")
        } catch {
            logger.info("Table successfully dropped - query failed as expected: \(error)")
        }

        // Test IF EXISTS
        _ = try await client.admin.dropTable(name: "drop_test", ifExists: true) // Should not error

        XCTAssertEqual(before, 1)
        logger.info("DROP TABLE operations completed successfully")
    }
}
