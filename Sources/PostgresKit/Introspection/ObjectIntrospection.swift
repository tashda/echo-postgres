
/// High-level object definition and comment introspection.
public extension PostgresMetadataClient {
    /// Fetch the SQL definition of a view.
    func viewDefinition(schema: String, view: String) async throws -> String? {
        let sql = "SELECT definition FROM pg_views WHERE schemaname = $1 AND viewname = $2"
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(view)])
            for row in rows { return try row.decode(String?.self) }
            return nil
        }
    }

    /// Fetch the SQL definition of a function.
    func functionDefinition(schema: String, name: String) async throws -> String? {
        let sql = """
            SELECT pg_catalog.pg_get_functiondef(p.oid)
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = $1 AND p.proname = $2
            ORDER BY p.oid LIMIT 1
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(name)])
            for row in rows { return try row.decode(String?.self) }
            return nil
        }
    }

    /// Fetch the SQL definition of a trigger.
    func triggerDefinition(schema: String, name: String) async throws -> String? {
        let sql = """
            SELECT pg_catalog.pg_get_triggerdef(t.oid, true)
            FROM pg_trigger t
            JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND t.tgname = $2
            ORDER BY t.oid LIMIT 1
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(name)])
            for row in rows { return try row.decode(String?.self) }
            return nil
        }
    }

    /// Fetch the comment/description for a table.
    func fetchTableComment(schema: String, table: String) async throws -> String? {
        let sql = "SELECT obj_description(format('%I.%I', $1::text, $2::text)::regclass, 'pg_class')"
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(table)])
            for row in rows { return try row.decode(String?.self) }
            return nil
        }
    }

    /// Fetch comments for all columns in a table.
    func fetchColumnComments(schema: String, table: String) async throws -> [PostgresColumnComment] {
        let sql = """
            SELECT a.attname, col_description(c.oid, a.attnum)
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
            WHERE n.nspname = $1 AND c.relname = $2
            ORDER BY a.attnum
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(table)])
            var out: [PostgresColumnComment] = []
            for row in rows {
                let (name, comment) = try row.decode((String, String?).self)
                out.append(PostgresColumnComment(column: name, comment: comment))
            }
            return out
        }
    }

    /// Fetch the comment for a function.
    func fetchFunctionComment(schema: String, name: String) async throws -> String? {
        let sql = """
            SELECT obj_description(p.oid, 'pg_proc')
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = $1 AND p.proname = $2
            ORDER BY p.oid LIMIT 1
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(name)])
            for row in rows { return try row.decode(String?.self) }
            return nil
        }
    }

    /// Fetch the comment for a trigger.
    func fetchTriggerComment(schema: String, name: String) async throws -> String? {
        let sql = """
            SELECT obj_description(t.oid, 'pg_trigger')
            FROM pg_trigger t
            JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND t.tgname = $2
            ORDER BY t.oid LIMIT 1
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(name)])
            for row in rows { return try row.decode(String?.self) }
            return nil
        }
    }

    /// Fetch the comment for the current database.
    func fetchDatabaseComment() async throws -> String? {
        let rows = try await client.simpleQuery("""
            SELECT obj_description(d.oid, 'pg_database')
            FROM pg_database d WHERE d.datname = current_database() LIMIT 1
            """)
        for try await value in rows.decode(String?.self) { return value }
        return nil
    }
}

