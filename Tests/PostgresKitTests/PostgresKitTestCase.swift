import XCTest
import Logging
import PostgresKitTesting

class PostgresKitTestCase: XCTestCase {
    let logger = Logger(label: "postgres.wire.tests")
    
    override class func setUp() {
        super.setUp()
        TestEnv.loadDotEnv()
    }
    
    override func setUp() async throws {
        try await super.setUp()
        
        // A lab server (Tests/with-lab.sh, or `serverlab up … --env`): load the sample data once.
        if PostgresLabFixture.isActive {
            try await PostgresLabFixture.ensureLoaded(logger: logger)
            return
        }

        // Ensure Docker is started if required before ANY test logic runs
        let useDocker = ProcessInfo.processInfo.environment["USE_DOCKER"]
        if useDocker == "1" {
            do {
                _ = try ensurePostgresTestFixture()
            } catch {
                XCTFail("Failed to start Postgres Docker container: \(error)")
                throw error
            }
        }
    }
}
