import Foundation

/// High-level table property and column detail introspection.
public extension PostgresMetadataClient {
    /// Fetch comprehensive table properties including storage parameters, owner, tablespace, etc.
    func fetchTableDetails(schema: String, table: String) async throws -> PostgresTableDetails {
        let sql = """
            SELECT
                c.oid::bigint AS oid,
                c.relname::text AS name,
                n.nspname::text AS schema,
                r.rolname::text AS owner,
                ts.spcname::text AS tablespace,
                c.relhasindex::text AS has_indexes,
                c.relhasrules::text AS has_rules,
                c.relhastriggers::text AS has_triggers,
                c.relrowsecurity::text AS row_security,
                c.relforcerowsecurity::text AS force_row_security,
                (c.relkind = 'p')::text AS is_partitioned,
                d.description::text AS description,
                c.relacl::text AS acl,
                c.reloptions::text AS options,
                COALESCE(s.n_live_tup, c.reltuples::bigint)::text AS estimated_rows,
                pg_total_relation_size(c.oid)::text AS total_size,
                pg_table_size(c.oid)::text AS table_size,
                pg_indexes_size(c.oid)::text AS indexes_size
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_roles r ON r.oid = c.relowner
            LEFT JOIN pg_tablespace ts ON ts.oid = c.reltablespace
            LEFT JOIN pg_description d ON d.objoid = c.oid AND d.objsubid = 0
            LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
            WHERE n.nspname = $1 AND c.relname = $2
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(table)])
            guard let row = rows.first else {
                throw PostgresError.objectNotFound("Table \(schema).\(table) not found")
            }
            let (
                oid, name, schemaName, owner, tablespace,
                hasIndexesStr, hasRulesStr, hasTriggersStr,
                rowSecStr, forceRowSecStr, isPartStr,
                description, acl, optionsStr,
                estRowsStr, totalSizeStr, tableSizeStr, indexesSizeStr
            ) = try row.decode((
                Int, String, String, String, String?,
                String, String, String,
                String, String, String,
                String?, String?, String?,
                String, String, String, String
            ).self)

            let hasIndexes = hasIndexesStr == "true" || hasIndexesStr == "t"
            let hasRules = hasRulesStr == "true" || hasRulesStr == "t"
            let hasTriggers = hasTriggersStr == "true" || hasTriggersStr == "t"
            let rowSecurity = rowSecStr == "true" || rowSecStr == "t"
            let forceRowSecurity = forceRowSecStr == "true" || forceRowSecStr == "t"
            let isPartitioned = isPartStr == "true" || isPartStr == "t"

            // Parse reloptions from text[] format: {fillfactor=90,autovacuum_enabled=true}
            var options: [String]?
            if let optionsStr {
                let cleaned = optionsStr.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                if !cleaned.isEmpty {
                    options = cleaned.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                }
            }

            return PostgresTableDetails(
                oid: oid,
                name: name,
                schema: schemaName,
                owner: owner,
                tablespace: tablespace,
                hasIndexes: hasIndexes,
                hasRules: hasRules,
                hasTriggers: hasTriggers,
                rowSecurity: rowSecurity,
                forceRowSecurity: forceRowSecurity,
                isPartitioned: isPartitioned,
                description: description,
                acl: acl,
                options: options,
                estimatedRowCount: Int(estRowsStr) ?? 0,
                totalSizeBytes: Int64(totalSizeStr) ?? 0,
                tableSizeBytes: Int64(tableSizeStr) ?? 0,
                indexesSizeBytes: Int64(indexesSizeStr) ?? 0
            )
        }
    }

    /// Fetch all column details for a table including defaults, identity, generated, comments.
    func fetchColumnDetails(schema: String, table: String) async throws -> [PostgresColumnDetails] {
        let sql = """
            SELECT
                a.attname::text AS name,
                pg_catalog.format_type(a.atttypid, a.atttypmod)::text AS data_type,
                a.attnum::text AS ordinal_position,
                (NOT a.attnotnull)::text AS is_nullable,
                pg_get_expr(d.adbin, d.adrelid)::text AS default_value,
                (a.attidentity != '')::text AS is_identity,
                CASE a.attidentity
                    WHEN 'a' THEN 'ALWAYS'
                    WHEN 'd' THEN 'BY DEFAULT'
                    ELSE NULL
                END::text AS identity_generation,
                (a.attgenerated != '')::text AS is_generated,
                pg_get_expr(d.adbin, d.adrelid)::text AS generation_expression,
                CASE WHEN a.attcollation <> 0 AND a.attcollation <> t.typcollation
                    THEN col.collname::text
                    ELSE NULL
                END AS collation,
                CASE WHEN a.attstattarget = -1 THEN NULL ELSE a.attstattarget END::text AS statistics_target,
                CASE a.attstorage
                    WHEN 'p' THEN 'PLAIN'
                    WHEN 'm' THEN 'MAIN'
                    WHEN 'e' THEN 'EXTERNAL'
                    WHEN 'x' THEN 'EXTENDED'
                    ELSE NULL
                END::text AS storage,
                dsc.description::text AS description,
                CASE WHEN a.atttypmod > 0 AND t.typname IN ('varchar', 'bpchar')
                    THEN (a.atttypmod - 4)
                    ELSE NULL
                END::text AS max_length
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            LEFT JOIN pg_collation col ON col.oid = a.attcollation
            LEFT JOIN pg_description dsc ON dsc.objoid = c.oid AND dsc.objsubid = a.attnum
            WHERE n.nspname = $1
              AND c.relname = $2
              AND a.attnum > 0
              AND NOT a.attisdropped
            ORDER BY a.attnum
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(table)])
            var out: [PostgresColumnDetails] = []
            for row in rows {
                let (
                    name, dataType, ordinalStr, isNullableStr,
                    defaultValue, isIdentityStr, identityGeneration,
                    isGeneratedStr, generationExpression, collation,
                    statsTargetStr, storage, description, maxLengthStr
                ) = try row.decode((
                    String, String, String, String,
                    String?, String, String?,
                    String, String?, String?,
                    String?, String?, String?, String?
                ).self)

                let ordinal = Int(ordinalStr) ?? 0
                let isNullable = isNullableStr == "true" || isNullableStr == "t"
                let isIdentity = isIdentityStr == "true" || isIdentityStr == "t"
                let isGenerated = isGeneratedStr == "true" || isGeneratedStr == "t"

                out.append(PostgresColumnDetails(
                    name: name,
                    dataType: dataType,
                    ordinalPosition: ordinal,
                    isNullable: isNullable,
                    defaultValue: isGenerated ? nil : defaultValue,
                    isIdentity: isIdentity,
                    identityGeneration: identityGeneration,
                    isGenerated: isGenerated,
                    generationExpression: isGenerated ? generationExpression : nil,
                    collation: collation,
                    statisticsTarget: statsTargetStr.flatMap { Int($0) },
                    storage: storage,
                    description: description,
                    maxLength: maxLengthStr.flatMap { Int($0) }
                ))
            }
            return out
        }
    }

    /// Check if a table has row-level security enabled.
    func fetchRLSStatus(schema: String, table: String) async throws -> PostgresRLSStatus {
        let sql = """
            SELECT
                c.relrowsecurity::text AS row_security,
                c.relforcerowsecurity::text AS force_row_security
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(table)])
            guard let row = rows.first else {
                throw PostgresError.objectNotFound("Table \(schema).\(table) not found")
            }
            let (rowSecStr, forceRowSecStr) = try row.decode((String, String).self)
            return PostgresRLSStatus(
                rowSecurity: rowSecStr == "true" || rowSecStr == "t",
                forceRowSecurity: forceRowSecStr == "true" || forceRowSecStr == "t"
            )
        }
    }

    /// List all triggers on a table.
    func listTriggers(schema: String, table: String) async throws -> [PostgresTriggerInfo] {
        let sql = """
            SELECT
                t.tgname::text AS name,
                CASE
                    WHEN (t.tgtype::int & 2) != 0 THEN 'BEFORE'
                    WHEN (t.tgtype::int & 64) != 0 THEN 'INSTEAD OF'
                    ELSE 'AFTER'
                END::text AS timing,
                CASE
                    WHEN (t.tgtype::int & 4) != 0 THEN 'INSERT'
                    WHEN (t.tgtype::int & 8) != 0 THEN 'DELETE'
                    WHEN (t.tgtype::int & 16) != 0 THEN 'UPDATE'
                    WHEN (t.tgtype::int & 32) != 0 THEN 'TRUNCATE'
                    ELSE 'UNKNOWN'
                END::text AS manipulation,
                CASE
                    WHEN (t.tgtype::int & 1) != 0 THEN 'ROW'
                    ELSE 'STATEMENT'
                END::text AS orientation,
                p.proname::text AS function_name,
                (t.tgenabled = 'O' OR t.tgenabled = 'A')::text AS is_enabled,
                pg_get_triggerdef(t.oid)::text AS definition
            FROM pg_trigger t
            JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_proc p ON p.oid = t.tgfoid
            WHERE n.nspname = $1
              AND c.relname = $2
              AND NOT t.tgisinternal
            ORDER BY t.tgname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(table)])
            var out: [PostgresTriggerInfo] = []
            for row in rows {
                let (name, timing, manipulation, orientation, functionName, isEnabledStr, definition) = try row.decode((String, String, String, String, String, String, String?).self)
                let isEnabled = isEnabledStr == "true" || isEnabledStr == "t"
                let event = "\(timing) \(manipulation)"
                out.append(PostgresTriggerInfo(
                    name: name,
                    event: event,
                    manipulation: manipulation,
                    orientation: orientation,
                    timing: timing,
                    functionName: functionName,
                    isEnabled: isEnabled,
                    definition: definition
                ))
            }
            return out
        }
    }
}
