import Foundation
@testable import PostgresKit
import PostgresKitTesting
import Testing

/// On a primary. A real standby (POSTGRES_TEST_STANDBY_URL) is in StandbyTests.
@Suite(.testServer)
struct PhysicalReplicationTests {
    @Test func primaryIsNotInRecoveryAndCannotBePromoted() async throws {
        let client = try await PostgresClient.connect(configuration: try #require(TestServer.current).configuration)
        defer { client.close() }
        #expect(try await client.metadata.isInRecovery() == false)
        // The primary of a pair has a standby (POSTGRES_TEST_STANDBY_URL); a lone server has none.
        if TestServer.url("POSTGRES_TEST_STANDBY_URL") == nil {
            #expect(try await client.metadata.listStandbys().isEmpty)
        }
        await #expect(throws: (any Error).self) { try await client.replication.promote(waitSeconds: 1) }
    }
}
