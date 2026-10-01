import Foundation

/// High-level schema and object discovery.
public extension PostgresMetadataClient {
    /// List all databases that are not templates.
    func listDatabases() async throws -> [String] {
        var names: [String] = []
        let rows = try await client.simpleQuery("SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname")
        for try await name in rows.decode(String.self) { names.append(name) }
        return names
    }

    /// Check if the current user has superuser privileges.
    func checkSuperuser() async throws -> Bool {
        let sql = "SELECT rolsuper FROM pg_roles WHERE rolname = current_user"
        let rows = try await client.simpleQuery(sql)
        for try await isSuper in rows.decode(Bool.self) {
            return isSuper
        }
        return false
    }

    /// List all user schemas.
    func listSchemas() async throws -> [PostgresSchemaInfo] {
        let sql = """
            SELECT n.oid::int, n.nspname, r.rolname,
                   obj_description(n.oid, 'pg_namespace'),
                   n.nspacl::text
            FROM pg_catalog.pg_namespace n
            JOIN pg_catalog.pg_roles r ON n.nspowner = r.oid
            WHERE n.nspname !~ '^pg_' AND n.nspname != 'information_schema'
            ORDER BY n.nspname
            """
        var results: [PostgresSchemaInfo] = []
        let rows = try await client.simpleQuery(sql)
        for try await v in rows.decode((Int, String, String, String?, String?).self) {
            results.append(PostgresSchemaInfo(oid: v.0, name: v.1, owner: v.2, description: v.3, acl: v.4))
        }
        return results
    }

    /// List tables and views within a schema.
    func listTablesAndViews(schema: String) async throws -> [SchemaObject] {
        let sql = """
            SELECT table_schema, table_name, table_type
            FROM information_schema.tables
            WHERE table_schema = $1
            ORDER BY table_name
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema)])
            var objects: [SchemaObject] = []
            for row in rows {
                let (s, n, t) = try row.decode((String, String, String).self)
                let kind: SchemaObjectKind
                switch t.uppercased() {
                case "BASE TABLE": kind = .table
                case "VIEW": kind = .view
                default: kind = .table
                }
                objects.append(SchemaObject(schema: s, name: n, kind: kind))
            }
            return objects
        }
    }

    /// List columns for a specific table or view.
    func listColumns(schema: String, table: String) async throws -> [PostgresColumnInfo] {
        let sql = """
            SELECT
                a.attname::text AS column_name,
                pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
                (NOT a.attnotnull)::text AS is_nullable,
                pg_get_expr(d.adbin, d.adrelid)::text AS column_default,
                CASE a.attidentity
                    WHEN 'a' THEN 'ALWAYS'
                    WHEN 'd' THEN 'BY DEFAULT'
                    ELSE NULL
                END::text AS identity_generation,
                CASE WHEN a.attcollation <> 0 AND a.attcollation <> t.typcollation
                    THEN col.collname::text
                    ELSE NULL
                END AS collation_name
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            LEFT JOIN pg_collation col ON col.oid = a.attcollation
            WHERE n.nspname = $1
              AND c.relname = $2
              AND a.attnum > 0
              AND NOT a.attisdropped
            ORDER BY a.attnum
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(table)])
            var out: [PostgresColumnInfo] = []
            for row in rows {
                let (name, dataType, nullable, defaultValue, identityGen, collation) = try row.decode((String, String, String, String?, String?, String?).self)
                let isNullable = nullable.uppercased().hasPrefix("T") || nullable == "1"
                let isIdentity = identityGen != nil
                out.append(PostgresColumnInfo(name: name, dataType: dataType, isNullable: isNullable, defaultValue: defaultValue, isIdentity: isIdentity, identityGeneration: identityGen, collation: collation))
            }
            return out
        }
    }

    /// Fetch all column details for all tables in a schema.
    func columnsByTable(schema: String) async throws -> [String: [PostgresColumnDetail]] {
        struct ColRec { let name: String; let type: String; let nullable: Bool; let maxLength: Int?; let ordinal: Int }
        
        let results = try await client.withConnection { conn in
            var columnsByTable: [String: [ColRec]] = [:]
            var primaryKeysByTable: [String: Set<String>] = [:]
            var foreignKeysByTable: [String: [String: PostgresColumnDetail.ForeignKeyRef]] = [:]

            // Standard columns
            let colSql = """
                SELECT table_name, column_name, data_type, is_nullable::text,
                       character_maximum_length::text, ordinal_position::text
                FROM information_schema.columns
                WHERE table_schema = $1
                ORDER BY table_name, ordinal_position
                """
            let colRows = try await conn.queryPreparedRows(colSql, binds: [client.bind(schema)])
            for row in colRows {
                let (table, column, dataType, nullableText, maxLenText, ordinalText) = try row.decode((String, String, String, String, String?, String).self)
                let isNullable = nullableText.uppercased() == "YES" || nullableText.uppercased() == "TRUE" || nullableText == "1"
                let maxLen = maxLenText.flatMap { Int($0) }
                let ordinal = Int(ordinalText) ?? 0
                columnsByTable[table, default: []].append(ColRec(name: column, type: dataType, nullable: isNullable, maxLength: maxLen, ordinal: ordinal))
            }

            // Primary keys
            let pkSql = """
                SELECT tc.table_name, kcu.column_name
                FROM information_schema.table_constraints AS tc
                JOIN information_schema.key_column_usage AS kcu
                  ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
                WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = $1
                """
            let pkRows = try await conn.queryPreparedRows(pkSql, binds: [client.bind(schema)])
            for row in pkRows {
                let (table, column) = try row.decode((String, String).self)
                primaryKeysByTable[table, default: []].insert(column)
            }

            // Foreign keys
            let fkSql = """
                SELECT cls.relname AS table_name, att.attname AS column_name,
                       nsp_ref.nspname AS ref_schema, cls_ref.relname AS ref_table,
                       att_ref.attname AS ref_column, con.conname AS constraint_name
                FROM pg_constraint con
                JOIN pg_class cls ON cls.oid = con.conrelid
                JOIN pg_namespace nsp ON nsp.oid = cls.relnamespace
                JOIN pg_class cls_ref ON cls_ref.oid = con.confrelid
                JOIN pg_namespace nsp_ref ON nsp_ref.oid = cls_ref.relnamespace
                JOIN LATERAL generate_subscripts(con.conkey, 1) AS idx(pos) ON TRUE
                JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = con.conkey[idx.pos]
                JOIN pg_attribute att_ref ON att_ref.attrelid = con.confrelid AND att_ref.attnum = con.confkey[idx.pos]
                WHERE con.contype = 'f' AND nsp.nspname = $1
                ORDER BY cls.relname, idx.pos
                """
            let fkRows = try await conn.queryPreparedRows(fkSql, binds: [client.bind(schema)])
            for row in fkRows {
                let (table, column, refSchema, refTable, refColumn, conname) = try row.decode((String, String, String, String, String, String).self)
                foreignKeysByTable[table, default: [:]][column] = PostgresColumnDetail.ForeignKeyRef(constraintName: conname, referencedSchema: refSchema, referencedTable: refTable, referencedColumn: refColumn)
            }

            // Materialized views
            let matSql = """
                SELECT c.relname, a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod),
                       (NOT a.attnotnull)::text, a.attnum::text
                FROM pg_attribute a
                JOIN pg_class c ON c.oid = a.attrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = $1 AND c.relkind = 'm' AND a.attnum > 0 AND NOT a.attisdropped
                ORDER BY c.relname, a.attnum
                """
            let matRows = try await conn.queryPreparedRows(matSql, binds: [client.bind(schema)])
            for row in matRows {
                let (table, column, dataType, nullableText, ordinalText) = try row.decode((String, String, String, String, String).self)
                let isNullable = nullableText.uppercased().hasPrefix("T") || nullableText == "1"
                let ordinal = Int(ordinalText) ?? 0
                columnsByTable[table, default: []].append(ColRec(name: column, type: dataType, nullable: isNullable, maxLength: nil, ordinal: ordinal))
            }
            
            return (columnsByTable, primaryKeysByTable, foreignKeysByTable)
        }

        var result: [String: [PostgresColumnDetail]] = [:]
        for (table, recs) in results.0 {
            let pkset = results.1[table] ?? []
            let fks = results.2[table] ?? [:]
            result[table] = recs.sorted { $0.ordinal < $1.ordinal }.map { r in
                PostgresColumnDetail(name: r.name, dataType: r.type, isNullable: r.nullable, maxLength: r.maxLength, isPrimaryKey: pkset.contains(r.name), foreignKey: fks[r.name])
            }
        }
        return result
    }

    /// List installed PostgreSQL extensions.
    func listExtensions() async throws -> [PostgresExtensionInfo] {
        let sql = """
            SELECT e.extname, n.nspname AS schema, e.extversion, e.extrelocatable
            FROM pg_extension e
            JOIN pg_namespace n ON n.oid = e.extnamespace
            ORDER BY e.extname
            """
        var out: [PostgresExtensionInfo] = []
        let rows = try await client.simpleQuery(sql)
        for try await (name, schema, version, reloc) in rows.decode((String, String, String, Bool).self) {
            out.append(PostgresExtensionInfo(name: name, schema: schema, version: version, relocatable: reloc))
        }
        return out
    }

    /// List all available PostgreSQL extensions (installed or not).
    func listAvailableExtensions() async throws -> [PostgresAvailableExtensionInfo] {
        let sql = """
            SELECT name, default_version, installed_version, comment
            FROM pg_available_extensions
            ORDER BY name
            """
        var out: [PostgresAvailableExtensionInfo] = []
        let rows = try await client.simpleQuery(sql)
        for try await (name, defVer, instVer, comment) in rows.decode((String, String, String?, String?).self) {
            out.append(PostgresAvailableExtensionInfo(name: name, defaultVersion: defVer, installedVersion: instVer, comment: comment))
        }
        return out
    }

    /// List all objects (tables, functions, types) owned by an extension.
    func listExtensionObjects(_ extensionName: String) async throws -> [PostgresExtensionObject] {
        let sql = """
            SELECT 
                n.nspname as schema,
                obj.objname as name,
                obj.objtype as type
            FROM (
                -- Tables, Views, Sequences, etc
                SELECT c.relnamespace, c.relname as objname, 
                       CASE c.relkind 
                         WHEN 'r' THEN 'TABLE' 
                         WHEN 'v' THEN 'VIEW' 
                         WHEN 'm' THEN 'MATERIALIZED VIEW' 
                         WHEN 'i' THEN 'INDEX' 
                         WHEN 'S' THEN 'SEQUENCE' 
                         ELSE 'OTHER' 
                       END as objtype,
                       c.oid
                FROM pg_class c
                UNION ALL
                -- Functions / Procedures
                SELECT p.pronamespace, p.proname, 'FUNCTION', p.oid
                FROM pg_proc p
                UNION ALL
                -- Types
                SELECT t.typnamespace, t.typname, 'TYPE', t.oid
                FROM pg_type t
            ) obj
            JOIN pg_depend d ON d.objid = obj.oid
            JOIN pg_extension e ON e.oid = d.refobjid
            JOIN pg_namespace n ON n.oid = obj.relnamespace
            WHERE d.refclassid = 'pg_extension'::regclass
              AND e.extname = \(client.quoteLiteral(extensionName))
            ORDER BY n.nspname, obj.objname
            """
        var out: [PostgresExtensionObject] = []
        let rows = try await client.simpleQuery(sql)
        for try await (schema, name, type) in rows.decode((String, String, String).self) {
            out.append(PostgresExtensionObject(schema: schema, name: name, type: type))
        }
        return out
    }
}

