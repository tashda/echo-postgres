import XCTest
import Logging
@testable import PostgresKit

final class IntegrationTests: PostgresKitTestCase {
    func testConnectAndSelectOneIfConfigured() async throws {
        guard TestEnv.isConfigured else {
            throw XCTSkip("Set POSTGRES_TEST_URL to run this test (see TESTING.md).")
        }
        
        let config = PostgresConfiguration(
            host: TestEnv.host,
            port: TestEnv.port,
            database: TestEnv.database,
            username: TestEnv.username,
            password: TestEnv.password,
            useTLS: TestEnv.useTLS,
            applicationName: "PostgresKitTests"
        )
        
        let client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: .init(label: "tests"))
        defer { client.close() }
        let rows = try await client.simpleQuery("SELECT 1")
        var values: [Int] = []
        for try await value in rows.decode(Int.self) { values.append(value) }
        XCTAssertEqual(values, [1])
    }
    
    func testSampleDataExists() async throws {
        guard TestEnv.isConfigured else {
            throw XCTSkip("Postgres environment not set")
        }
        
        let config = PostgresConfiguration(
            host: TestEnv.host,
            port: TestEnv.port,
            database: TestEnv.database,
            username: TestEnv.username,
            password: TestEnv.password,
            useTLS: TestEnv.useTLS
        )
        
        // Use a small retry loop for the connection to handle potential transient Docker startup issues
        var client: PostgresClient?
        var lastError: Error?
        
        for _ in 0..<5 {
            do {
                client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: .init(label: "tests"))
                break
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 2_000_000_000) // Wait 2s and retry
            }
        }
        
        guard let connectedClient = client else {
            throw lastError ?? NSError(domain: "IntegrationTests", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to connect after retries"])
        }
        
        defer { connectedClient.close() }
        
        // Check if our sample users table exists and has data
        do {
            let rows = try await connectedClient.simpleQuery("SELECT count(*) FROM app.users")
            var countFound = false
            for try await count in rows.decode(Int64.self) {
                XCTAssertGreaterThan(count, 0, "Sample data should have at least one user")
                countFound = true
            }
            XCTAssertTrue(countFound, "Should have returned a count")
        } catch {
            let pgError = PostgresError.from(error)
            logger.error("testSampleDataExists failed: \(pgError.message)")
            let debug = pgError.withDebugging()
            if !debug.serverInfo.isEmpty {
                 logger.error("Server Info: \(debug.serverInfo)")
            }
            logger.error("Full Reflection: \(String(reflecting: error))")
            throw error
        }
    }
}
