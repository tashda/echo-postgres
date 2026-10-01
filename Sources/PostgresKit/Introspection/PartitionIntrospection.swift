import Foundation

/// Partition and inheritance introspection queries.
public extension PostgresMetadataClient {
    /// Check if a table is partitioned and get partition info.
    func fetchPartitionInfo(schema: String, table: String) async throws -> PostgresPartitionInfo? {
        let sql = """
            SELECT
                CASE p.partstrat
                    WHEN 'r' THEN 'RANGE'
                    WHEN 'l' THEN 'LIST'
                    WHEN 'h' THEN 'HASH'
                END::text AS strategy,
                pg_get_partkeydef(c.oid)::text AS partition_key,
                (SELECT count(*)::text FROM pg_inherits i WHERE i.inhparent = c.oid) AS partition_count
            FROM pg_partitioned_table p
            JOIN pg_class c ON c.oid = p.partrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(table)])
            guard let row = rows.first else { return nil }
            let (strategyStr, partitionKey, partitionCountStr) = try row.decode((String, String, String).self)
            guard let strategy = PartitionStrategy(rawValue: strategyStr) else { return nil }
            return PostgresPartitionInfo(
                strategy: strategy,
                partitionKey: partitionKey,
                partitionCount: Int(partitionCountStr) ?? 0
            )
        }
    }

    /// List all partitions of a partitioned table.
    func listPartitions(schema: String, table: String) async throws -> [PostgresPartitionDetail] {
        let sql = """
            SELECT
                cn.nspname::text AS schema_name,
                cc.relname::text AS partition_name,
                pg_get_expr(cc.relpartbound, cc.oid)::text AS bound_spec,
                pg_table_size(cc.oid)::text AS size_bytes,
                COALESCE(s.n_live_tup, cc.reltuples::bigint)::text AS estimated_rows
            FROM pg_inherits i
            JOIN pg_class pc ON pc.oid = i.inhparent
            JOIN pg_namespace pn ON pn.oid = pc.relnamespace
            JOIN pg_class cc ON cc.oid = i.inhrelid
            JOIN pg_namespace cn ON cn.oid = cc.relnamespace
            LEFT JOIN pg_stat_user_tables s ON s.relid = cc.oid
            WHERE pn.nspname = $1 AND pc.relname = $2
              AND cc.relispartition = true
            ORDER BY cn.nspname, cc.relname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(table)])
            var out: [PostgresPartitionDetail] = []
            for row in rows {
                let (schemaName, partitionName, boundSpec, sizeBytesStr, estimatedRowsStr) = try row.decode((String, String, String, String, String).self)
                out.append(PostgresPartitionDetail(
                    schemaName: schemaName,
                    partitionName: partitionName,
                    boundSpec: boundSpec,
                    sizeBytes: Int64(sizeBytesStr) ?? 0,
                    estimatedRows: Int(estimatedRowsStr) ?? 0
                ))
            }
            return out
        }
    }

    /// List parent tables (inheritance parents) of a table.
    func listInheritanceParents(schema: String, table: String) async throws -> [PostgresInheritanceInfo] {
        let sql = """
            SELECT
                pn.nspname::text AS parent_schema,
                pc.relname::text AS parent_table
            FROM pg_inherits i
            JOIN pg_class cc ON cc.oid = i.inhrelid
            JOIN pg_namespace cn ON cn.oid = cc.relnamespace
            JOIN pg_class pc ON pc.oid = i.inhparent
            JOIN pg_namespace pn ON pn.oid = pc.relnamespace
            WHERE cn.nspname = $1 AND cc.relname = $2
              AND NOT cc.relispartition
            ORDER BY pn.nspname, pc.relname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(table)])
            var out: [PostgresInheritanceInfo] = []
            for row in rows {
                let (schemaName, tableName) = try row.decode((String, String).self)
                out.append(PostgresInheritanceInfo(schemaName: schemaName, tableName: tableName))
            }
            return out
        }
    }

    /// List child tables that inherit from this table.
    func listInheritanceChildren(schema: String, table: String) async throws -> [PostgresInheritanceInfo] {
        let sql = """
            SELECT
                cn.nspname::text AS child_schema,
                cc.relname::text AS child_table
            FROM pg_inherits i
            JOIN pg_class pc ON pc.oid = i.inhparent
            JOIN pg_namespace pn ON pn.oid = pc.relnamespace
            JOIN pg_class cc ON cc.oid = i.inhrelid
            JOIN pg_namespace cn ON cn.oid = cc.relnamespace
            WHERE pn.nspname = $1 AND pc.relname = $2
              AND NOT cc.relispartition
            ORDER BY cn.nspname, cc.relname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(table)])
            var out: [PostgresInheritanceInfo] = []
            for row in rows {
                let (schemaName, tableName) = try row.decode((String, String).self)
                out.append(PostgresInheritanceInfo(schemaName: schemaName, tableName: tableName))
            }
            return out
        }
    }
}
