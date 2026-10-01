import Foundation

/// A standby streaming from this server (`pg_stat_replication`).
public struct PostgresStandbyInfo: Sendable, Equatable {
    public let applicationName: String
    public let clientAddress: String?
    /// `streaming`, `catchup`, `startup`, …
    public let state: String
    /// `async`, `sync`, `potential` or `quorum`.
    public let syncState: String
}

/// Physical (streaming) replication: promoting a standby.
public extension PostgresReplicationClient {
    /// Promotes this standby to a primary (`pg_promote`). With `wait`, returns once promotion
    /// finished or `waitSeconds` passed; returns whether it succeeded.
    @discardableResult
    func promote(wait: Bool = true, waitSeconds: Int = 60) async throws -> Bool {
        let rows = try await client.simpleQuery("SELECT pg_promote(\(wait ? "true" : "false"), \(max(1, waitSeconds)))")
        for try await promoted in rows.decode(Bool.self) { return promoted }
        return false
    }
}

public extension PostgresMetadataClient {
    /// True on a standby (the server is replaying WAL), false on a primary.
    func isInRecovery() async throws -> Bool {
        let rows = try await client.simpleQuery("SELECT pg_is_in_recovery()")
        for try await inRecovery in rows.decode(Bool.self) { return inRecovery }
        return false
    }

    /// Standbys connected to this primary.
    func listStandbys() async throws -> [PostgresStandbyInfo] {
        let rows = try await client.simpleQuery(
            "SELECT application_name::text, client_addr::text, state::text, sync_state::text FROM pg_stat_replication ORDER BY application_name"
        )
        var standbys: [PostgresStandbyInfo] = []
        for try await (name, address, state, sync) in rows.decode((String, String?, String?, String?).self) {
            standbys.append(PostgresStandbyInfo(applicationName: name, clientAddress: address, state: state ?? "", syncState: sync ?? ""))
        }
        return standbys
    }
}
