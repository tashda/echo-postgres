import Foundation
import Logging
import PostgresKit

enum TestEnv {
    private static let logger = Logger(label: "postgres.wire.tests")
    /// Loads `.env` from the working directory. With a lab server (`SERVERLAB_CONTAINER`) or
    /// `USE_DOCKER=1`, `POSTGRES_*` entries are ignored so a `.env` that points at a real server can
    /// never redirect tests away from the disposable one.
    static func loadDotEnv() {
        let dockerManaged = getEnv("USE_DOCKER") == "1" || getEnv("SERVERLAB_CONTAINER") != nil
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        let envPath = (cwd as NSString).appendingPathComponent(".env")
        guard fm.fileExists(atPath: envPath) else { return }
        if let content = try? String(contentsOfFile: envPath, encoding: .utf8) {
            for line in content.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                if let eq = trimmed.firstIndex(of: "=") {
                    let key = String(trimmed[..<eq])
                    let value = String(trimmed[trimmed.index(after: eq)...])
                    if dockerManaged && key.hasPrefix("POSTGRES_") { continue }
                    setenv(key, value, 1)
                }
            }
        }
    }

    private static func getEnv(_ key: String) -> String? {
        // Try getenv first (for setenv compatibility)
        if let value = getenv(key) {
            return String(cString: value)
        }
        // Fallback to ProcessInfo
        return ProcessInfo.processInfo.environment[key]
    }

    static var isConfigured: Bool {
        let host = getEnv("POSTGRES_HOST")
        let useDocker = getEnv("USE_DOCKER")
        let configured = host != nil || useDocker == "1"
        if !configured {
            logger.warning("TestEnv NOT configured. POSTGRES_HOST: \(host ?? "nil"), USE_DOCKER: \(useDocker ?? "nil")")
        }
        return configured
    }

    static var host: String {
        getEnv("POSTGRES_HOST") ?? "127.0.0.1"
    }

    static var port: Int {
        if let portStr = getEnv("POSTGRES_PORT"),
           let port = Int(portStr) {
            return port
        }
        return 5432
    }

    static var username: String {
        getEnv("POSTGRES_USERNAME") ?? "postgres"
    }

    static var password: String? {
        getEnv("POSTGRES_PASSWORD") ?? "postgres"
    }

    static var database: String {
        getEnv("POSTGRES_DATABASE") ?? "postgres"
    }

    static var useTLS: Bool {
        (getEnv("POSTGRES_TLS") ?? "false").lowercased() == "true"
    }

    /// Configuration for the test server, with optional overrides for the settings under test.
    static func configuration(
        database: String? = nil,
        username: String? = nil,
        password: String? = nil,
        applicationName: String? = "postgres-wire-tests",
        pool: PostgresPoolConfiguration = .init(),
        statementTimeout: Duration? = nil
    ) -> PostgresConfiguration {
        PostgresConfiguration(
            host: host,
            port: port,
            database: database ?? self.database,
            username: username ?? self.username,
            password: password ?? self.password,
            sslMode: useTLS ? .require : .disable,
            applicationName: applicationName,
            pool: pool,
            statementTimeout: statementTimeout
        )
    }
}
