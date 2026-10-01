import Foundation
import PGLibpq

/// How the bundled `pg_dump`, `pg_restore`, `pg_dumpall` and `psql` reach a server exactly as the
/// connection does (Echo #34): its hosts, TLS mode, CA and client certificate, Kerberos service,
/// target session and application name, as one libpq connection string for `--dbname`. The
/// password goes in the environment, never on the command line. Keep the value until the tool
/// has finished: client certificates converted for it are deleted with it.
public struct PostgresToolConnection: Sendable {
    /// For `--dbname=` (`-d`); holds no password.
    public let connectionString: String
    /// `PGPASSWORD` when the connection signs in with one.
    public let environment: [String: String]
    /// Holds the converted certificate files.
    let setup: PostgresLibpqSetup
}

/// Why the tools can't use the connection's settings.
public enum PostgresToolConnectionError: LocalizedError, Equatable, Sendable {
    /// libpq would take the key password only on the command line, where other users can read it.
    case encryptedClientKey

    public var errorDescription: String? {
        switch self {
        case .encryptedClientKey:
            "The PostgreSQL tools can't use an encrypted client key. Use a key without a password, or a .p12 file, for backups and restores."
        }
    }
}

extension PostgresConfiguration {
    /// The tools' connection to `database` (this configuration's database when nil).
    public func toolConnection(database: String? = nil) async throws -> PostgresToolConnection {
        var configuration = self
        if let database { configuration.database = database }
        let password = try await PostgresPool.password(for: configuration)
        let setup = try await configuration.libpqSetup(password: nil)
        let parameters = setup.parameters.closedToTheEnvironment()
        guard parameters["sslpassword"] == nil else { throw PostgresToolConnectionError.encryptedClientKey }
        var environment: [String: String] = [:]
        if let password, !password.isEmpty { environment["PGPASSWORD"] = password }
        return PostgresToolConnection(
            connectionString: Self.connectionString(parameters),
            environment: environment,
            setup: setup
        )
    }

    /// `keyword='value' …`, quoted as libpq reads it (backslash before `'` and `\`).
    static func connectionString(_ parameters: PGConnectionParameters) -> String {
        parameters.entries
            .filter { $0.keyword != "password" && $0.keyword != "sslpassword" }
            .map { entry in
                let value = entry.value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                return "\(entry.keyword)='\(value)'"
            }
            .joined(separator: " ")
    }
}

extension PostgresClient {
    /// The tools' connection to `database`, as this client connects (its configuration).
    public func toolConnection(database: String? = nil) async throws -> PostgresToolConnection {
        try await pool.configuration.toolConnection(database: database)
    }
}
