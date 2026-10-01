import Foundation
import Logging
import NIOConcurrencyHelpers
import PostgresKit
import PostgresKitTesting
import XCTest

/// The XCTest suites' sample data (`Support/SampleData.sql`) in a database of the run's own on the
/// `POSTGRES_TEST_URL` server, created through the driver when the first suite starts and dropped
/// (with the roles the data made) when the test bundle finishes. The server is left as it was.
enum SampleDatabase {
    private static let state = NIOLockedValueBox<String?>(nil)
    private static let loader = LoadOnce()
    private static let observerRegistered = NIOLockedValueBox(false)
    static let roles = ["test_readonly", "test_readwrite", "test_app_user"]

    /// The database's name once prepared.
    static var name: String? { state.withLockedValue { $0 } }

    /// Creates the database and loads the sample data, once per test process.
    static func prepare(logger: Logger) async throws {
        try await loader.run {
            guard let server = TestServer.url() else { return }
            let name = "postgres_wire_test_" + UUID().uuidString.prefix(8).lowercased()
            let admin = try await PostgresClient.connect(configuration: server.configuration, logger: logger)
            defer { admin.close() }
            try await admin.admin.createDatabase(name: name)
            state.withLockedValue { $0 = name }
            var configuration = server.configuration
            configuration.database = name
            let client = try await PostgresClient.connect(configuration: configuration, logger: logger)
            defer { client.close() }
            _ = try await client.scripts.run(contentsOf: sampleDataURL)
            logger.info("Sample data loaded into \(name)")
        }
    }

    /// Drops the database when the test bundle finishes (registered by the first suite).
    static func registerCleanup() {
        let first = observerRegistered.withLockedValue { registered -> Bool in
            defer { registered = true }
            return !registered
        }
        if first { XCTestObservationCenter.shared.addTestObserver(Cleanup()) }
    }

    /// Drops the database, and the sample roles unless another run's database still uses them.
    static func drop() async {
        guard let name, let server = TestServer.url() else { return }
        let logger = Logger(label: "postgres.wire.tests")
        guard let admin = try? await PostgresClient.connect(configuration: server.configuration, logger: logger) else { return }
        defer { admin.close() }
        _ = try? await admin.admin.dropDatabase(name: name, ifExists: true, withForce: true)
        let others = try? await admin.simpleQueryResult("SELECT count(*)::text FROM pg_database WHERE datname LIKE 'postgres_wire_test_%'")
        if let cell = others?.rows.first?.first, PostgresCellFormatter().stringValue(for: cell) == "0" {
            for role in roles { _ = try? await admin.simpleQueryResult("DROP ROLE IF EXISTS \(PostgresQuoting.quoteIdentifier(role))") }
        }
        state.withLockedValue { $0 = nil }
    }

    private static var sampleDataURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SampleData.sql")
    }

    private final class Cleanup: NSObject, XCTestObservation, @unchecked Sendable {
        func testBundleDidFinish(_ testBundle: Bundle) {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await SampleDatabase.drop()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 30)
        }
    }
}

/// Runs the loader once; later callers wait for the first and share its outcome.
actor LoadOnce {
    private var task: Task<Void, any Error>?

    func run(_ body: @escaping @Sendable () async throws -> Void) async throws {
        if let task { return try await task.value }
        let started = Task { try await body() }
        task = started
        try await started.value
    }
}
