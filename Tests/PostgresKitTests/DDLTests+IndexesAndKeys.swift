import XCTest
import Logging
@testable import PostgresKit

extension DDLTests {
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
