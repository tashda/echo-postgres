import Foundation

/// Monitoring and statistics introspection.
public extension PostgresMetadataClient {

    // MARK: - Table I/O Statistics

    /// Fetch table I/O statistics from pg_statio_user_tables.
    func fetchTableIOStats(schema: String, table: String) async throws -> PostgresTableIOStats? {
        let sql = """
            SELECT
                schemaname::text,
                relname::text,
                COALESCE(heap_blks_read, 0)::text,
                COALESCE(heap_blks_hit, 0)::text,
                COALESCE(idx_blks_read, 0)::text,
                COALESCE(idx_blks_hit, 0)::text,
                COALESCE(toast_blks_read, 0)::text,
                COALESCE(toast_blks_hit, 0)::text
            FROM pg_statio_user_tables
            WHERE schemaname = \(client.quoteLiteral(schema))
              AND relname = \(client.quoteLiteral(table))
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            guard let row = rows.first else { return nil }
            let (schemaName, tableName, heapRead, heapHit, idxRead, idxHit, toastRead, toastHit) =
                try row.decode((String, String, String, String, String, String, String, String).self)
            return PostgresTableIOStats(
                schemaName: schemaName, tableName: tableName,
                heapBlksRead: Int64(heapRead) ?? 0, heapBlksHit: Int64(heapHit) ?? 0,
                idxBlksRead: Int64(idxRead) ?? 0, idxBlksHit: Int64(idxHit) ?? 0,
                toastBlksRead: Int64(toastRead) ?? 0, toastBlksHit: Int64(toastHit) ?? 0
            )
        }
    }

    /// Fetch all table I/O stats for a schema.
    func listTableIOStats(schema: String) async throws -> [PostgresTableIOStats] {
        let sql = """
            SELECT
                schemaname::text,
                relname::text,
                COALESCE(heap_blks_read, 0)::text,
                COALESCE(heap_blks_hit, 0)::text,
                COALESCE(idx_blks_read, 0)::text,
                COALESCE(idx_blks_hit, 0)::text,
                COALESCE(toast_blks_read, 0)::text,
                COALESCE(toast_blks_hit, 0)::text
            FROM pg_statio_user_tables
            WHERE schemaname = \(client.quoteLiteral(schema))
            ORDER BY relname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresTableIOStats] = []
            for row in rows {
                let (schemaName, tableName, heapRead, heapHit, idxRead, idxHit, toastRead, toastHit) =
                    try row.decode((String, String, String, String, String, String, String, String).self)
                out.append(PostgresTableIOStats(
                    schemaName: schemaName, tableName: tableName,
                    heapBlksRead: Int64(heapRead) ?? 0, heapBlksHit: Int64(heapHit) ?? 0,
                    idxBlksRead: Int64(idxRead) ?? 0, idxBlksHit: Int64(idxHit) ?? 0,
                    toastBlksRead: Int64(toastRead) ?? 0, toastBlksHit: Int64(toastHit) ?? 0
                ))
            }
            return out
        }
    }

    // MARK: - WAL Statistics

    /// Fetch WAL statistics (PG14+).
    func fetchWALStats() async throws -> PostgresWALStats? {
        let sql = """
            SELECT
                COALESCE(wal_records, 0)::text,
                COALESCE(wal_fpi, 0)::text,
                COALESCE(wal_bytes, 0)::text,
                COALESCE(wal_buffers_full, 0)::text,
                COALESCE(wal_write, 0)::text,
                COALESCE(wal_sync, 0)::text,
                COALESCE(wal_write_time, 0)::text,
                COALESCE(wal_sync_time, 0)::text,
                stats_reset::text
            FROM pg_stat_wal
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            guard let row = rows.first else { return nil }
            let (records, fpi, bytes, bufFull, write, sync, writeTime, syncTime, statsReset) =
                try row.decode((String, String, String, String, String, String, String, String, String?).self)
            return PostgresWALStats(
                walRecords: Int64(records) ?? 0, walFPI: Int64(fpi) ?? 0,
                walBytes: Int64(bytes) ?? 0, walBuffersFull: Int64(bufFull) ?? 0,
                walWrite: Int64(write) ?? 0, walSync: Int64(sync) ?? 0,
                walWriteTime: Double(writeTime) ?? 0, walSyncTime: Double(syncTime) ?? 0,
                statsReset: statsReset
            )
        }
    }

    // MARK: - Background Writer Statistics

    /// Fetch background writer statistics.
    func fetchBGWriterStats() async throws -> PostgresBGWriterStats {
        let sql = """
            SELECT
                COALESCE(checkpoints_timed, 0)::text,
                COALESCE(checkpoints_req, 0)::text,
                COALESCE(checkpoint_write_time, 0)::text,
                COALESCE(checkpoint_sync_time, 0)::text,
                COALESCE(buffers_checkpoint, 0)::text,
                COALESCE(buffers_clean, 0)::text,
                COALESCE(maxwritten_clean, 0)::text,
                COALESCE(buffers_backend, 0)::text,
                COALESCE(buffers_backend_fsync, 0)::text,
                COALESCE(buffers_alloc, 0)::text
            FROM pg_stat_bgwriter
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            guard let row = rows.first else {
                return PostgresBGWriterStats(
                    checkpointsTimed: 0, checkpointsReq: 0,
                    checkpointWriteTime: 0, checkpointSyncTime: 0,
                    buffersCheckpoint: 0, buffersClean: 0,
                    maxwrittenClean: 0, buffersBackend: 0,
                    buffersBackendFsync: 0, buffersAlloc: 0
                )
            }
            let (timed, req, writeTime, syncTime, bufChk, bufClean, maxClean, bufBack, bufFsync, bufAlloc) =
                try row.decode((String, String, String, String, String, String, String, String, String, String).self)
            return PostgresBGWriterStats(
                checkpointsTimed: Int64(timed) ?? 0, checkpointsReq: Int64(req) ?? 0,
                checkpointWriteTime: Double(writeTime) ?? 0, checkpointSyncTime: Double(syncTime) ?? 0,
                buffersCheckpoint: Int64(bufChk) ?? 0, buffersClean: Int64(bufClean) ?? 0,
                maxwrittenClean: Int64(maxClean) ?? 0, buffersBackend: Int64(bufBack) ?? 0,
                buffersBackendFsync: Int64(bufFsync) ?? 0, buffersAlloc: Int64(bufAlloc) ?? 0
            )
        }
    }

    // MARK: - Prepared Transactions

    /// List prepared (two-phase) transactions.
    func listPreparedTransactions() async throws -> [PostgresPreparedTransaction] {
        let sql = """
            SELECT
                transaction::text,
                gid::text,
                prepared::text,
                owner::text,
                database::text
            FROM pg_prepared_xacts
            ORDER BY prepared
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresPreparedTransaction] = []
            for row in rows {
                let (txid, gid, prepared, owner, database) =
                    try row.decode((String, String, String, String, String).self)
                out.append(PostgresPreparedTransaction(
                    transactionID: txid, gid: gid, prepared: prepared,
                    owner: owner, database: database
                ))
            }
            return out
        }
    }

    // MARK: - Server Settings

    /// Fetch server settings from pg_settings with categories and context.
    func listServerSettings(category: String? = nil, search: String? = nil) async throws -> [PostgresServerSetting] {
        var conditions: [String] = []
        if let category {
            conditions.append("category = \(client.quoteLiteral(category))")
        }
        if let search {
            let pattern = client.quoteLiteral("%\(search)%")
            conditions.append("(name ILIKE \(pattern) OR short_desc ILIKE \(pattern))")
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT
                name::text,
                setting::text,
                unit::text,
                category::text,
                short_desc::text,
                context::text,
                vartype::text,
                source::text,
                min_val::text,
                max_val::text,
                enumvals::text,
                boot_val::text,
                reset_val::text,
                pending_restart::text
            FROM pg_settings
            \(whereClause)
            ORDER BY category, name
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresServerSetting] = []
            for row in rows {
                let (name, setting, unit, cat, desc, ctx, vartype, source, minV, maxV, enumStr, bootV, resetV, pendingStr) =
                    try row.decode((String, String, String?, String, String, String, String, String, String?, String?, String?, String?, String?, String).self)
                let enumVals: [String]?
                if let enumStr, !enumStr.isEmpty {
                    let cleaned = enumStr.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                    enumVals = cleaned.isEmpty ? nil : cleaned.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                } else {
                    enumVals = nil
                }
                let pendingRestart = pendingStr == "true" || pendingStr == "t" || pendingStr == "on"
                out.append(PostgresServerSetting(
                    name: name, setting: setting, unit: unit,
                    category: cat, shortDesc: desc, context: ctx,
                    vartype: vartype, source: source,
                    minVal: minV, maxVal: maxV,
                    enumVals: enumVals, bootVal: bootV, resetVal: resetV,
                    pendingRestart: pendingRestart
                ))
            }
            return out
        }
    }

    // MARK: - Object Search

    /// Search all database objects by name pattern.
    func searchObjects(pattern: String, limit: Int = 50) async throws -> [PostgresSearchResult] {
        let likePattern = client.quoteLiteral("%\(pattern)%")
        let sql = """
            (
                SELECT
                    CASE c.relkind
                        WHEN 'r' THEN 'TABLE'
                        WHEN 'v' THEN 'VIEW'
                        WHEN 'm' THEN 'MATERIALIZED VIEW'
                        WHEN 'S' THEN 'SEQUENCE'
                        WHEN 'f' THEN 'FOREIGN TABLE'
                        WHEN 'p' THEN 'PARTITIONED TABLE'
                        ELSE 'TABLE'
                    END::text AS object_type,
                    n.nspname::text AS schema_name,
                    c.relname::text AS object_name
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relname ILIKE \(likePattern)
                  AND c.relkind IN ('r', 'v', 'm', 'S', 'f', 'p')
                  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
            )
            UNION ALL
            (
                SELECT
                    'FUNCTION'::text AS object_type,
                    n.nspname::text AS schema_name,
                    p.proname::text AS object_name
                FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE p.proname ILIKE \(likePattern)
                  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
            )
            UNION ALL
            (
                SELECT
                    'TYPE'::text AS object_type,
                    n.nspname::text AS schema_name,
                    t.typname::text AS object_name
                FROM pg_type t
                JOIN pg_namespace n ON n.oid = t.typnamespace
                WHERE t.typname ILIKE \(likePattern)
                  AND t.typtype IN ('e', 'c', 'd', 'r')
                  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
            )
            UNION ALL
            (
                SELECT
                    'SCHEMA'::text AS object_type,
                    n.nspname::text AS schema_name,
                    n.nspname::text AS object_name
                FROM pg_namespace n
                WHERE n.nspname ILIKE \(likePattern)
                  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
                  AND n.nspname !~ '^pg_temp'
            )
            ORDER BY schema_name, object_name
            LIMIT \(limit)
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresSearchResult] = []
            for row in rows {
                let (objectType, schemaName, objectName) =
                    try row.decode((String, String, String).self)
                out.append(PostgresSearchResult(objectType: objectType, schemaName: schemaName, objectName: objectName))
            }
            return out
        }
    }
}
