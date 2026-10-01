import Foundation
import PostgresWire

/// High-level constraint and dependency introspection.
public extension PostgresMetadataClient {
    /// Fetch primary key information for a table.
    func primaryKey(schema: String, table: String) async throws -> PostgresPrimaryKeyInfo? {
        let sql = """
            SELECT
                c.conname::text AS constraint_name,
                a.attname::text AS column_name,
                c.condeferrable::text AS is_deferrable,
                c.condeferred::text AS is_deferred
            FROM pg_constraint c
            JOIN pg_class cl ON cl.oid = c.conrelid
            JOIN pg_namespace ns ON ns.oid = cl.relnamespace
            CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS u(attnum, ord)
            JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = u.attnum
            WHERE c.contype = 'p'
              AND ns.nspname = $1
              AND cl.relname = $2
            ORDER BY u.ord
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.toPGData(value: schema), client.toPGData(value: table)])
            var name: String?
            var cols: [String] = []
            var isDeferrable = false
            var isDeferred = false
            for row in rows {
                let (n, c, defStr, dfdStr) = try row.decode((String, String, String?, String?).self)
                name = n
                cols.append(c)
                isDeferrable = defStr == "true" || defStr == "t"
                isDeferred = dfdStr == "true" || dfdStr == "t"
            }
            if let name { return PostgresPrimaryKeyInfo(name: name, columns: cols, isDeferrable: isDeferrable, isInitiallyDeferred: isDeferred) }
            return nil
        }
    }

    /// List all foreign keys for a table.
    func foreignKeys(schema: String, table: String) async throws -> [PostgresForeignKeyInfo] {
        struct Row { let name: String; let column: String; let refSchema: String; let refTable: String; let refColumn: String; let onUpdate: String?; let onDelete: String?; let position: Int; let isDeferrable: Bool; let isDeferred: Bool }
        let sql = """
            SELECT
                c.conname::text AS constraint_name,
                a.attname::text AS column_name,
                rns.nspname::text AS ref_schema,
                rcl.relname::text AS ref_table,
                ra.attname::text AS ref_column,
                CASE c.confupdtype
                    WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT'
                    WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
                    WHEN 'd' THEN 'SET DEFAULT' ELSE NULL
                END::text AS update_rule,
                CASE c.confdeltype
                    WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT'
                    WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
                    WHEN 'd' THEN 'SET DEFAULT' ELSE NULL
                END::text AS delete_rule,
                u.ord::text AS ordinal_position,
                c.condeferrable::text AS is_deferrable,
                c.condeferred::text AS is_deferred
            FROM pg_constraint c
            JOIN pg_class cl ON cl.oid = c.conrelid
            JOIN pg_namespace ns ON ns.oid = cl.relnamespace
            JOIN pg_class rcl ON rcl.oid = c.confrelid
            JOIN pg_namespace rns ON rns.oid = rcl.relnamespace
            CROSS JOIN LATERAL unnest(c.conkey, c.confkey) WITH ORDINALITY AS u(local_attnum, ref_attnum, ord)
            JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = u.local_attnum
            JOIN pg_attribute ra ON ra.attrelid = c.confrelid AND ra.attnum = u.ref_attnum
            WHERE c.contype = 'f'
              AND ns.nspname = $1
              AND cl.relname = $2
            ORDER BY c.conname, u.ord
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.toPGData(value: schema), client.toPGData(value: table)])
            var fks: [String: [Row]] = [:]
            for row in rows {
                let (name, column, refSchema, refTable, refColumn, onUpdate, onDelete, posStr, deferrableStr, deferredStr) = try row.decode((String, String, String, String, String, String?, String?, String, String?, String?).self)
                let position = Int(posStr) ?? 0
                let isDeferrable = deferrableStr == "true" || deferrableStr == "t"
                let isDeferred = deferredStr == "true" || deferredStr == "t"
                fks[name, default: []].append(Row(name: name, column: column, refSchema: refSchema, refTable: refTable, refColumn: refColumn, onUpdate: onUpdate, onDelete: onDelete, position: position, isDeferrable: isDeferrable, isDeferred: isDeferred))
            }
            return fks.sorted { $0.key < $1.key }.map { name, rows in
                let sorted = rows.sorted { $0.position < $1.position }
                return PostgresForeignKeyInfo(name: name, columns: sorted.map { $0.column }, referencedSchema: sorted.first!.refSchema, referencedTable: sorted.first!.refTable, referencedColumns: sorted.map { $0.refColumn }, onUpdate: sorted.first!.onUpdate, onDelete: sorted.first!.onDelete, isDeferrable: sorted.first!.isDeferrable, isInitiallyDeferred: sorted.first!.isDeferred)
            }
        }
    }

    /// List all unique constraints for a table.
    func uniqueConstraints(schema: String, table: String) async throws -> [PostgresUniqueConstraintInfo] {
        let sql = """
            SELECT
                c.conname::text AS constraint_name,
                a.attname::text AS column_name,
                c.condeferrable::text AS is_deferrable,
                c.condeferred::text AS is_deferred
            FROM pg_constraint c
            JOIN pg_class cl ON cl.oid = c.conrelid
            JOIN pg_namespace ns ON ns.oid = cl.relnamespace
            CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS u(attnum, ord)
            JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = u.attnum
            WHERE c.contype = 'u'
              AND ns.nspname = $1
              AND cl.relname = $2
            ORDER BY c.conname, u.ord
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.toPGData(value: schema), client.toPGData(value: table)])
            struct Entry { var columns: [String] = []; var isDeferrable = false; var isDeferred = false }
            var map: [String: Entry] = [:]
            for row in rows {
                let (name, column, defStr, dfdStr) = try row.decode((String, String, String?, String?).self)
                var entry = map[name] ?? Entry()
                entry.columns.append(column)
                entry.isDeferrable = defStr == "true" || defStr == "t"
                entry.isDeferred = dfdStr == "true" || dfdStr == "t"
                map[name] = entry
            }
            return map.sorted { $0.key < $1.key }.map { PostgresUniqueConstraintInfo(name: $0.key, columns: $0.value.columns, isDeferrable: $0.value.isDeferrable, isInitiallyDeferred: $0.value.isDeferred) }
        }
    }

    /// List all dependencies on a specific table (i.e., which tables reference this one).
    func dependencies(schema: String, table: String) async throws -> [PostgresDependencyInfo] {
        let sql = """
            SELECT tc.constraint_name::text, kcu.table_schema::text, kcu.table_name::text,
                   kcu.column_name::text, ccu.column_name::text, rc.update_rule::text,
                   rc.delete_rule::text, kcu.ordinal_position::text
            FROM information_schema.referential_constraints AS rc
            JOIN information_schema.table_constraints AS tc
              ON tc.constraint_name = rc.constraint_name AND tc.constraint_schema = rc.constraint_schema
            JOIN information_schema.key_column_usage AS kcu
              ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = kcu.table_schema
            JOIN information_schema.constraint_column_usage AS ccu
              ON ccu.constraint_name = tc.constraint_name AND ccu.constraint_schema = tc.constraint_schema
            WHERE ccu.table_schema = $1 AND ccu.table_name = $2
            ORDER BY tc.constraint_name, kcu.ordinal_position
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.toPGData(value: schema), client.toPGData(value: table)])
            struct Row { let name: String; let srcSchema: String; let srcTable: String; let srcColumn: String; let tgtColumn: String; let onUpdate: String?; let onDelete: String?; let pos: Int }
            var map: [String: [Row]] = [:]
            for row in rows {
                let (name, sourceSchema, sourceTable, sourceColumn, targetColumn, onUpdate, onDelete, posStr) = try row.decode((String, String, String, String, String, String?, String?, String).self)
                let position = Int(posStr) ?? 0
                map[name, default: []].append(Row(name: name, srcSchema: sourceSchema, srcTable: sourceTable, srcColumn: sourceColumn, tgtColumn: targetColumn, onUpdate: onUpdate, onDelete: onDelete, pos: position))
            }
            return map.sorted { $0.key < $1.key }.map { name, rows in
                let sorted = rows.sorted { $0.pos < $1.pos }
                let srcTable = sorted.first.map { r in r.srcSchema == schema ? r.srcTable : "\(r.srcSchema).\(r.srcTable)" } ?? ""
                return PostgresDependencyInfo(name: name, sourceTable: srcTable, referencingColumns: sorted.map { $0.srcColumn }, referencedColumns: sorted.map { $0.tgtColumn }, onUpdate: sorted.first?.onUpdate, onDelete: sorted.first?.onDelete)
            }
        }
    }

    /// List all indexes for a table.
    func listIndexes(schema: String, table: String) async throws -> [PostgresIndexInfo] {
        let sql = """
        SELECT
            idx.relname::text AS index_name,
            ix.indisunique::text,
            ord.position::text,
            att.attname::text,
            ((ix.indoption[ord.position] & 1) = 1)::text AS is_descending,
            pg_get_expr(ix.indpred, tab.oid)::text AS predicate,
            am.amname::text AS index_type,
            ix.indnkeyatts::text AS num_key_columns,
            ix.indisvalid::text AS is_valid
        FROM pg_class tab
        JOIN pg_index ix ON tab.oid = ix.indrelid
        JOIN pg_class idx ON idx.oid = ix.indexrelid
        JOIN pg_namespace ns ON ns.oid = tab.relnamespace
        JOIN pg_am am ON am.oid = idx.relam
        CROSS JOIN LATERAL generate_subscripts(ix.indkey, 1) AS ord(position)
        LEFT JOIN pg_attribute att ON att.attrelid = tab.oid AND att.attnum = ix.indkey[ord.position]
        WHERE ns.nspname = $1
          AND tab.relname = $2
          AND ix.indisprimary = false
        ORDER BY idx.relname, ord.position
        """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.toPGData(value: schema), client.toPGData(value: table)])
            var acc: [String: (unique: Bool, cols: [PostgresIndexInfo.Column], predicate: String?, indexType: String?, numKeyColumns: Int)] = [:]
            var invalid: Set<String> = []
            for row in rows {
                let (indexName, isUniqueStr, posStr, attname, isDescStr, predicate, indexType, numKeyStr, isValidStr) = try row.decode((String, String, String, String?, String?, String?, String?, String?, String).self)
                if isValidStr == "false" || isValidStr == "f" { invalid.insert(indexName) }
                let isUnique = isUniqueStr == "true" || isUniqueStr == "t"
                let position = Int(posStr) ?? 0
                let numKeyColumns = Int(numKeyStr ?? "0") ?? 0
                var entry = acc[indexName] ?? (isUnique, [], nil, indexType, numKeyColumns)
                if let attname {
                    let isDesc = isDescStr == "true" || isDescStr == "t"
                    let isIncluded = numKeyColumns > 0 && position >= numKeyColumns
                    entry.cols.append(PostgresIndexInfo.Column(name: attname, isDescending: isDesc, isIncluded: isIncluded))
                }
                entry.unique = isUnique
                entry.predicate = predicate
                entry.indexType = indexType
                acc[indexName] = entry
            }
            return acc.sorted { $0.key < $1.key }.map { name, e in
                PostgresIndexInfo(name: name, isUnique: e.unique, columns: e.cols, predicate: e.predicate, indexType: e.indexType,
                                  isValid: !invalid.contains(name))
            }
        }
    }

    /// Fetch table-level storage properties from reloptions.
    func tableProperties(schema: String, table: String) async throws -> PostgresTableProperties {
        let sql = """
            SELECT
                c.reloptions::text AS reloptions,
                ts.spcname::text AS tablespace
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_tablespace ts ON ts.oid = c.reltablespace
            WHERE n.nspname = $1 AND c.relname = $2
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.toPGData(value: schema), client.toPGData(value: table)])
            var fillfactor: Int?
            var toastTupleTarget: Int?
            var autovacuumEnabled: Bool?
            var parallelWorkers: Int?
            var tablespace: String?
            for row in rows {
                let (reloptionsStr, ts) = try row.decode((String?, String?).self)
                tablespace = ts
                // reloptions is a text[] like {fillfactor=90,toast_tuple_target=128}
                if let opts = reloptionsStr {
                    let cleaned = opts.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                    for pair in cleaned.split(separator: ",") {
                        let parts = pair.split(separator: "=", maxSplits: 1)
                        guard parts.count == 2 else { continue }
                        let key = parts[0].trimmingCharacters(in: .whitespaces)
                        let value = parts[1].trimmingCharacters(in: .whitespaces)
                        switch key {
                        case "fillfactor": fillfactor = Int(value)
                        case "toast_tuple_target": toastTupleTarget = Int(value)
                        case "autovacuum_enabled": autovacuumEnabled = value == "true" || value == "on"
                        case "parallel_workers": parallelWorkers = Int(value)
                        default: break
                        }
                    }
                }
            }
            return PostgresTableProperties(fillfactor: fillfactor, toastTupleTarget: toastTupleTarget, autovacuumEnabled: autovacuumEnabled, parallelWorkers: parallelWorkers, tablespace: tablespace)
        }
    }

    /// List all check constraints for a table.
    func checkConstraints(schema: String, table: String) async throws -> [PostgresCheckConstraintInfo] {
        let sql = """
            SELECT
                c.conname::text AS constraint_name,
                pg_get_constraintdef(c.oid)::text AS constraint_def
            FROM pg_constraint c
            JOIN pg_class cl ON cl.oid = c.conrelid
            JOIN pg_namespace ns ON ns.oid = cl.relnamespace
            WHERE c.contype = 'c'
              AND ns.nspname = $1
              AND cl.relname = $2
            ORDER BY c.conname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.toPGData(value: schema), client.toPGData(value: table)])
            var out: [PostgresCheckConstraintInfo] = []
            for row in rows {
                let (name, def) = try row.decode((String, String).self)
                // pg_get_constraintdef returns "CHECK ((expression))" — strip the outer CHECK wrapper
                var expression = def
                if expression.hasPrefix("CHECK (") && expression.hasSuffix(")") {
                    expression = String(expression.dropFirst(7).dropLast(1))
                }
                out.append(PostgresCheckConstraintInfo(name: name, expression: expression))
            }
            return out
        }
    }
}

