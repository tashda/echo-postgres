import Foundation
@testable import PostgresKit
import Testing

/// On a primary. Promotion of a real standby is covered by echo-server-lab's pg-*-primary-standby recipes.
@Suite(.enabled(if: TestEnv.isConfigured))
struct PhysicalReplicationTests {
    @Test func primaryIsNotInRecoveryAndCannotBePromoted() async throws {
        let client = try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port, database: TestEnv.database,
            username: TestEnv.username, password: TestEnv.password, useTLS: TestEnv.useTLS
        ))
        defer { client.close() }
        #expect(try await client.metadata.isInRecovery() == false)
        #expect(try await client.metadata.listStandbys().isEmpty)
        await #expect(throws: (any Error).self) { try await client.replication.promote(waitSeconds: 1) }
    }
}
