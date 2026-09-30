import Foundation
import Logging
import PostgresKit

/// The test fixture on a disposable server from echo-server-lab, the way tests use a database
/// server: `serverlab up <recipe> --env` starts one (on `testlab`) and sets `SERVERLAB_CONTAINER`
/// and `POSTGRES_*`; the suite loads `SampleData.sql` into it through the driver's own script runner
/// (the lab allows no psql); `serverlab down` removes it afterwards. `Tests/with-lab.sh` does all
/// three. Nothing stays running.
public enum PostgresLabFixture {
    /// Whether the environment points at a lab server.
    public static var isActive: Bool {
        environment("SERVERLAB_CONTAINER") != nil && environment("POSTGRES_HOST") != nil
    }

    private static let loaded = LoadOnce()

    /// Loads the sample data into the lab server once per test process (and not at all when the
    /// server already has it, for example when several test processes share one server).
    public static func ensureLoaded(logger: Logger = Logger(label: "postgres.wire.lab-fixture")) async throws {
        try await loaded.run {
            let client = try await PostgresClient.connect(configuration: configuration(), logger: logger)
            defer { client.close() }
            if try await hasSampleData(client) { return }
            let summary = try await client.scripts.run(contentsOf: sampleDataURL)
            guard try await hasSampleData(client) else {
                throw PostgresFixtureError.unavailable("SampleData.sql ran (\(summary)) but the fixture is incomplete on the lab server.")
            }
            logger.info("Loaded SampleData.sql into lab server \(environment("SERVERLAB_CONTAINER") ?? "")")
        }
    }

    static func configuration() -> PostgresConfiguration {
        PostgresConfiguration(
            host: environment("POSTGRES_HOST") ?? "127.0.0.1",
            port: environment("POSTGRES_PORT").flatMap(Int.init) ?? 5432,
            database: environment("POSTGRES_DATABASE") ?? "postgres",
            username: environment("POSTGRES_USERNAME") ?? "postgres",
            password: environment("POSTGRES_PASSWORD"),
            applicationName: "postgres-wire tests (fixture)",
            connectTimeout: 15
        )
    }

    private static func hasSampleData(_ client: PostgresClient) async throws -> Bool {
        let result = try await client.simpleQueryResult("""
            SELECT (EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'app' AND table_name = 'users')
                AND EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'audit')
                AND EXISTS (SELECT 1 FROM pg_type WHERE typname = 'mood')
                AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'test_readonly')
                AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'uuid-ossp'))::text
            """)
        guard let cell = result.rows.first?.first else { return false }
        return PostgresCellFormatter().stringValue(for: cell) == "true"
    }

    private static var sampleDataURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/PostgresKitTests/Support/SampleData.sql")
    }

    private static func environment(_ key: String) -> String? {
        getenv(key).map { String(cString: $0) } ?? ProcessInfo.processInfo.environment[key]
    }
}

/// Runs the loader once; later callers wait for the first and share its outcome.
private actor LoadOnce {
    private var task: Task<Void, any Error>?

    func run(_ body: @escaping @Sendable () async throws -> Void) async throws {
        if let task { return try await task.value }
        let started = Task { try await body() }
        task = started
        try await started.value
    }
}
