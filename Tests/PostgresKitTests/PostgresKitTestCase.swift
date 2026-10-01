import XCTest
import Logging
import PostgresKitTesting

/// Base class of the XCTest suites: they need `POSTGRES_TEST_URL` (skipped without it, failed
/// without it under `POSTGRES_TEST_REQUIRED=1`) and run on the run's sample database.
class PostgresKitTestCase: XCTestCase {
    let logger = Logger(label: "postgres.wire.tests")

    override class func setUp() {
        super.setUp()
        SampleDatabase.registerCleanup()
    }

    override func setUp() async throws {
        try await super.setUp()
        guard TestServer.url() != nil else {
            if TestServer.isRequired() {
                throw TestServerURLError(description: "\(TestServer.urlVariable) is not set and \(TestServer.requiredVariable)=1. "
                    + TestServer.missingMessage(TestServer.urlVariable))
            }
            throw XCTSkip(TestServer.missingMessage(TestServer.urlVariable))
        }
        try await SampleDatabase.prepare(logger: logger)
    }
}
