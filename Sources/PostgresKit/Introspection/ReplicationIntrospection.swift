import Foundation

/// Logical replication introspection.
public extension PostgresMetadataClient {
    /// List all publications in the current database.
    func listPublications() async throws -> [PostgresPublicationInfo] {
        let sql = """
            SELECT
                p.pubname::text AS name,
                r.rolname::text AS owner,
                p.puballtables::text AS all_tables,
                p.pubinsert::text AS publish_insert,
                p.pubupdate::text AS publish_update,
                p.pubdelete::text AS publish_delete,
                p.pubtruncate::text AS publish_truncate
            FROM pg_publication p
            JOIN pg_roles r ON r.oid = p.pubowner
            ORDER BY p.pubname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresPublicationInfo] = []
            for row in rows {
                let (name, owner, allTablesStr, insertStr, updateStr, deleteStr, truncateStr) =
                    try row.decode((String, String, String, String, String, String, String).self)
                out.append(PostgresPublicationInfo(
                    name: name,
                    owner: owner,
                    allTables: allTablesStr == "true" || allTablesStr == "t",
                    publishInsert: insertStr == "true" || insertStr == "t",
                    publishUpdate: updateStr == "true" || updateStr == "t",
                    publishDelete: deleteStr == "true" || deleteStr == "t",
                    publishTruncate: truncateStr == "true" || truncateStr == "t"
                ))
            }
            return out
        }
    }

    /// List tables belonging to a publication.
    func listPublicationTables(publication: String) async throws -> [PostgresPublicationTableInfo] {
        let sql = """
            SELECT
                schemaname::text AS schema_name,
                tablename::text AS table_name
            FROM pg_publication_tables
            WHERE pubname = \(client.quoteLiteral(publication))
            ORDER BY schemaname, tablename
            """
        var out: [PostgresPublicationTableInfo] = []
        let rows = try await client.simpleQuery(sql)
        for try await (schemaName, tableName) in rows.decode((String, String).self) {
            out.append(PostgresPublicationTableInfo(schemaName: schemaName, tableName: tableName))
        }
        return out
    }

    /// List all subscriptions in the current database.
    func listSubscriptions() async throws -> [PostgresSubscriptionInfo] {
        let sql = """
            SELECT
                s.subname::text AS name,
                r.rolname::text AS owner,
                s.subenabled::text AS enabled,
                s.subconninfo::text AS connection_info,
                s.subpublications::text AS publications,
                s.subslotname::text AS slot_name
            FROM pg_subscription s
            JOIN pg_roles r ON r.oid = s.subowner
            ORDER BY s.subname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresSubscriptionInfo] = []
            for row in rows {
                let (name, owner, enabledStr, connectionInfo, publicationsStr, slotName) =
                    try row.decode((String, String, String, String, String?, String?).self)

                // Parse text array format: {pub1,pub2}
                var publications: [String] = []
                if let publicationsStr {
                    let cleaned = publicationsStr.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                    if !cleaned.isEmpty {
                        publications = cleaned.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                    }
                }

                out.append(PostgresSubscriptionInfo(
                    name: name,
                    owner: owner,
                    enabled: enabledStr == "true" || enabledStr == "t",
                    connectionInfo: connectionInfo,
                    publications: publications,
                    slotName: slotName
                ))
            }
            return out
        }
    }

    /// List all replication slots.
    func listReplicationSlots() async throws -> [PostgresReplicationSlotInfo] {
        let sql = """
            SELECT
                slot_name::text,
                plugin::text,
                slot_type::text,
                active::text,
                confirmed_flush_lsn::text
            FROM pg_replication_slots
            ORDER BY slot_name
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresReplicationSlotInfo] = []
            for row in rows {
                let (slotName, plugin, slotType, activeStr, confirmedFlushLSN) =
                    try row.decode((String, String?, String, String, String?).self)
                out.append(PostgresReplicationSlotInfo(
                    slotName: slotName,
                    plugin: plugin,
                    slotType: slotType,
                    active: activeStr == "true" || activeStr == "t",
                    confirmedFlushLSN: confirmedFlushLSN
                ))
            }
            return out
        }
    }
}
