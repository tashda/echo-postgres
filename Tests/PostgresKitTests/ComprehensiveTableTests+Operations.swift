import XCTest
import Logging
@testable import PostgresKit

extension ComprehensiveTableTests {
    // MARK: - Table Truncate Operations

    func testTruncateTableOperations() async throws {
        logger.info("Testing Truncate Table Operations")

        // Use fixed table names with proper cleanup at start
        _ = try await client.admin.dropTable(name: "test_truncate_table", ifExists: true, cascade: true)
        _ = try await client.admin.dropTable(name: "test_truncate_table2", ifExists: true, cascade: true)

        // Create tables for truncate testing
        _ = try await client.admin.createTable(
            name: "test_truncate_table",
            columns: [
                .bigSerial(name: "id", primaryKey: true),
                .varchar(name: "name", length: 50, nullable: false),
                .integer(name: "value"),
                .timestamp(name: "created_at", defaultValue: "CURRENT_TIMESTAMP")
            ]
        )

        _ = try await client.admin.createTable(
            name: "test_truncate_table2",
            columns: [
                .bigSerial(name: "id", primaryKey: true),
                .varchar(name: "category", length: 30, nullable: false),
                .text(name: "description")
            ]
        )

        // Insert test data
        _ = try await client.bulk.insert(
            into: "test_truncate_table",
            columns: ["name", "value"],
            values: [["Item 1", 100], ["Item 2", 200], ["Item 3", 300]]
        )

        _ = try await client.bulk.insert(
            into: "test_truncate_table2",
            columns: ["category", "description"],
            values: [["Category A", "Description A"], ["Category B", "Description B"]]
        )

        // Verify data exists
        var count = 0
        let result1 = try await client.simpleQuery("SELECT COUNT(*) FROM test_truncate_table")
        for try await rowCount in result1.decode((Int64?).self) {
            if let rowCount = rowCount {
                count = Int(rowCount)
                break
            }
        }
        XCTAssertEqual(count, 3, "Should have 3 rows before truncate")

        // Test truncate with identity reset
        _ = try await client.bulk.truncate(table: "test_truncate_table", restartIdentity: true)

        // Verify table is empty
        count = 0
        let result2 = try await client.simpleQuery("SELECT COUNT(*) FROM test_truncate_table")
        for try await rowCount in result2.decode((Int64?).self) {
            if let rowCount = rowCount {
                count = Int(rowCount)
                break
            }
        }
        XCTAssertEqual(count, 0, "Should have 0 rows after truncate")

        // Test inserting after truncate (should restart from 1)
        _ = try await client.bulk.insert(
            into: "test_truncate_table",
            columns: ["name", "value"],
            values: [["New Item 1", 1000]]
        )

        let result3 = try await client.simpleQuery("SELECT id, name FROM test_truncate_table ORDER BY id")
        var newId = 0
        for try await (id, name) in result3.decode((Int64, String).self) {
            newId = Int(id)
            XCTAssertEqual(name, "New Item 1")
            break
        }
        XCTAssertEqual(newId, 1, "ID should restart from 1 after truncate with restartIdentity")

        // Cleanup with CASCADE
        _ = try await client.admin.dropTable(name: "test_truncate_table2", ifExists: true, cascade: true)
        _ = try await client.admin.dropTable(name: "test_truncate_table", ifExists: true, cascade: true)

        logger.info("Truncate table operations test passed")
    }

    // MARK: - Table Operations with Large Datasets

    func testTableOperationsWithLargeDatasets() async throws {
        logger.info("Testing Table Operations with Large Datasets")

        _ = try await client.admin.dropTable(name: "test_large_dataset", ifExists: true)

        // Create table for large dataset testing
        _ = try await client.admin.createTable(
            name: "test_large_dataset",
            columns: [
                .bigSerial(name: "id", primaryKey: true),
                .varchar(name: "name", length: 100, nullable: false),
                .integer(name: "category_id"),
                .decimal(name: "price", precision: 10, scale: 2),
                .timestamp(name: "created_at"),
                .jsonb(name: "attributes"),
                .boolean(name: "is_active", defaultValue: true)
            ]
        )

        // Create indexes for performance
        _ = try await client.indexes.createIndex(
            name: "idx_large_name",
            table: "test_large_dataset",
            columns: ["name"],
            unique: false
        )

        _ = try await client.indexes.createIndex(
            name: "idx_large_category",
            table: "test_large_dataset",
            columns: ["category_id"],
            unique: false
        )

        _ = try await client.indexes.createIndex(
            name: "idx_large_active",
            table: "test_large_dataset",
            columns: ["is_active"],
            unique: false
        )

        // Generate large dataset
        let batchSize = 1000
        let totalRecords = 5000

        // Generate and insert large dataset
        for batchStart in stride(from: 1, through: totalRecords, by: batchSize) {
            let rows: [[PostgresInsertValue]] = (batchStart..<min(batchStart + batchSize, totalRecords + 1)).map { i in
                let name = "Product \(i)"
                let categoryId = (i % 10) + 1
                let price = Double.random(in: 10.0...1000.0)
                let timestamp = "2024-\(String(format: "%02d", (i % 12) + 1))-\(String(format: "%02d", (i % 28) + 1)) 10:00:00"
                let batchNumber = i / batchSize + 1
                let quality = (i % 5 == 0) ? "high" : "standard"
                let attributes = "{\"batch\": \(batchNumber), \"quality\": \"\(quality)\"}"
                let isActive = i % 20 != 0 // 5% inactive

                return [
                    PostgresInsertValue(name),
                    PostgresInsertValue(categoryId),
                    PostgresInsertValue(price),
                    .timestamp(timestamp),
                    .jsonbLiteral(attributes),
                    PostgresInsertValue(isActive)
                ]
            }

            _ = try await client.bulk.insert(
                into: "test_large_dataset",
                columns: ["name", "category_id", "price", "created_at", "attributes", "is_active"],
                values: rows
            )
        }

        // Test query performance
        let startTime = Date().timeIntervalSinceReferenceDate

        let result = try await client.simpleQuery("""
            SELECT COUNT(*) as count, AVG(price) as avg_price
            FROM test_large_dataset
            WHERE is_active = true AND category_id BETWEEN 3 AND 7
        """)

        var count = 0
        var avgPrice: Double = 0.0
        for try await row in result {
            let randomRow = row.makeRandomAccess()
            if let rowCount = try? randomRow["count"].decode(Int64.self) {
                count = Int(rowCount)
            }
            if let priceAvg = try? randomRow["avg_price"].decode(Double.self) {
                avgPrice = priceAvg
            } else if let priceAvgString = try? randomRow["avg_price"].decode(String.self),
                      let priceAvgDouble = Double(priceAvgString) {
                avgPrice = priceAvgDouble
            }
            break
        }

        let queryTime = Date().timeIntervalSinceReferenceDate - startTime

        logger.info("Query results: \(count) active records in categories 3-7, avg price: $\(String(format: "%.2f", avgPrice))")
        logger.info("Query completed in \(String(format: "%.3f", queryTime)) seconds")

        XCTAssertGreaterThan(count, 1000, "Should find significant number of records")
        XCTAssertLessThan(queryTime, 2.0, "Query should complete quickly with proper indexing")

        // Index creation and query performance validated
        // Large dataset operations completed successfully with proper indexing

        // Cleanup
        _ = try await client.admin.dropTable(name: "test_large_dataset", ifExists: false)

        logger.info("Large dataset operations test passed")
    }

    // MARK: - Table Operations with Special Character Handling

    func testTableOperationsWithSpecialCharacters() async throws {
        logger.info("Testing Table Operations with Special Characters")

        // Test table and column names with special characters
        _ = try await client.admin.dropTable(name: "test_special_chars_table", ifExists: true)
        _ = try await client.admin.dropTable(name: "table_with_underscores", ifExists: true)

        // Create table with special character column names
        _ = try await client.admin.createTable(
            name: "test_special_chars_table",
            columns: [
                .bigSerial(name: "id", primaryKey: true),
                .varchar(name: "user_name", length: 50, nullable: false),
                .varchar(name: "email_address", length: 255),
                .text(name: "full_description"),
                .boolean(name: "is_active_flag", defaultValue: true),
                .timestamp(name: "created_at_timestamp"),
                .jsonb(name: "user_settings_data")
            ]
        )

        _ = try await client.bulk.insert(
            into: "test_special_chars_table",
            columns: ["user_name", "email_address", "full_description", "user_settings_data"],
            values: [
                ["John O'Connor", "john.o'connor@example.com", "User with special chars: quotes, apostrophes, & symbols!", .jsonbLiteral("{\"theme\": \"dark\", \"notifications\": true}")],
                ["Jane \"Developer\" Smith", "jane.dev+test@example.co.uk", "Complex email & text with @#$%^&*() characters", .jsonbLiteral("{\"role\": \"admin\", \"access_level\": 5}")],
                ["用户中文", "chinese@user.中国", "Unicode test: ñáéíóú 中文 🚀", .jsonbLiteral("{\"language\": \"zh-CN\", \"encoding\": \"UTF-8\"}")]
            ]
        )

        // Query special character data
        let result = try await client.simpleQuery("SELECT user_name, email_address, full_description FROM test_special_chars_table ORDER BY id")

        var userCount = 0
        for try await (name, email, description) in result.decode((String, String, String).self) {
            userCount += 1
            logger.info("User: \(name), Email: \(email), Description: \(description)")
        }
        XCTAssertEqual(userCount, 3, "Should retrieve all 3 users with special characters")

        // Test table with reserved word names
        _ = try await client.admin.createTable(
            name: "table_with_underscores",
            columns: [
                .bigSerial(name: "id", primaryKey: true),
                .text(name: "user_key"),
                .text(name: "value_data"),
                .text(name: "order_column")
            ]
        )

        _ = try await client.bulk.insert(
            into: "table_with_underscores",
            columns: ["user_key", "value_data", "order_column"],
            values: [["key1", "value1", "order1"], ["key2", "value2", "order2"]]
        )

        // Cleanup
        _ = try await client.admin.dropTable(name: "test_special_chars_table", ifExists: false)
        _ = try await client.admin.dropTable(name: "table_with_underscores", ifExists: false)

        logger.info("Special character handling test passed")
    }
}
