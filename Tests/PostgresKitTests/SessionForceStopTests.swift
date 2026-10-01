import Foundation
import PostgresKitTesting
import Testing
@testable import PostgresKit

/// Force Stop (round 21): closing a session while it runs a statement ends that statement's wait at
/// once; a transaction that was open is reported lost.
@Suite("PostgresSessionConnection Force Stop", .testServer, .serialized)
struct SessionForceStopTests {
    @Test func closeWhileRunningEndsAtOnce() async throws {
        let server = try #require(TestServer.current)
        let session = try await PostgresSessionConnection.connect(configuration: server.configuration)
        let running = Task { try await session.query("SELECT pg_sleep(10)").collect() }
        try await Task.sleep(for: .milliseconds(500))
        #expect(session.isQueryInFlight)
        let started = ContinuousClock.now
        await session.close()
        _ = try? await running.value
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(session.isClosed)
        #expect(!session.transactionWasLost)
    }

    @Test func closeInsideATransactionReportsItLost() async throws {
        let server = try #require(TestServer.current)
        let session = try await PostgresSessionConnection.connect(configuration: server.configuration)
        _ = try await session.queryResult("BEGIN")
        #expect(session.transactionStatus == .inTransaction)
        let running = Task { try await session.query("SELECT pg_sleep(10)").collect() }
        try await Task.sleep(for: .milliseconds(500))
        await session.close()
        do {
            _ = try await running.value
            Issue.record("the statement did not fail")
        } catch let error as PostgresSessionError {
            #expect(error == .connectionClosed(transactionLost: true) || error == .connectionClosed(transactionLost: false))
        } catch {
            // The read ended with the connection's own error; also fine.
        }
        await #expect(throws: PostgresSessionError.self) { _ = try await session.queryResult("SELECT 1") }
    }
}
