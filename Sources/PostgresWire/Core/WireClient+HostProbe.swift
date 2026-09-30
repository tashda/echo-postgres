import Foundation
import Logging
import PostgresNIO

/// One configured server as a connection test saw it.
public struct PostgresHostProbe: @unchecked Sendable {
    public enum Role: String, Sendable {
        /// Not in recovery: accepts writes.
        case primary
        /// In recovery: a read-only standby.
        case standby
    }

    public let host: PostgresHost
    /// The server's role, or nil when it couldn't be reached or refused the sign-in (see ``error``).
    public let role: Role?
    public let error: (any Error)?
    /// How long connecting and asking took.
    public let elapsed: Duration
}

extension PostgresWireClient {
    /// Connects to every configured host at once (``PostgresWireConfiguration/host`` and
    /// ``PostgresWireConfiguration/additionalHosts``, in that order) and asks whether it is a primary
    /// or a standby, for a connection test that checks each server rather than the one a connect
    /// would choose. Each connection is closed again.
    public static func probeHosts(configuration: PostgresWireConfiguration, logger: Logger) async -> [PostgresHostProbe] {
        let hosts = [PostgresHost(host: configuration.host, port: configuration.port)] + configuration.additionalHosts
        let credential: PostgresCredential
        do {
            credential = try await configuration.passwordProvider?() ?? PostgresCredential(password: configuration.password)
        } catch {
            return hosts.map { PostgresHostProbe(host: $0, role: nil, error: error, elapsed: .zero) }
        }
        return await withTaskGroup(of: (Int, PostgresHostProbe).self) { group in
            for (index, host) in hosts.enumerated() {
                group.addTask {
                    let clock = ContinuousClock()
                    let start = clock.now
                    let candidate = configuration.resolved(host: host, sslMode: configuration.sslMode, password: credential.password)
                    do {
                        let (connection, _) = try await openWithSSLFallback(candidate, id: index, logger: logger)
                        defer { Task { try? await connection.close() } }
                        var inRecovery = ""
                        for try await value in try await connection.query("SELECT pg_is_in_recovery()::text", logger: logger).decode(String.self) {
                            inRecovery = value
                        }
                        return (index, PostgresHostProbe(host: host, role: inRecovery == "true" ? .standby : .primary, error: nil, elapsed: clock.now - start))
                    } catch {
                        return (index, PostgresHostProbe(host: host, role: nil, error: error, elapsed: clock.now - start))
                    }
                }
            }
            var probes: [(Int, PostgresHostProbe)] = []
            for await probe in group { probes.append(probe) }
            return probes.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
