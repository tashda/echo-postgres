
/// Detailed type introspection for the type editor.
public extension PostgresMetadataClient {

    /// Fetch the ordered values of an enum type.
    func enumValues(schema: String, name: String) async throws -> [String] {
        let sql = """
            SELECT e.enumlabel::text
            FROM pg_enum e
            JOIN pg_type t ON t.oid = e.enumtypid
            JOIN pg_namespace n ON n.oid = t.typnamespace
            WHERE n.nspname = $1 AND t.typname = $2
            ORDER BY e.enumsortorder
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [
                client.bind(schema),
                client.bind(name)
            ])
            return try rows.map { try $0.decode(String.self) }
        }
    }

    /// Fetch the owner of a type.
    func typeOwner(schema: String, name: String) async throws -> String? {
        let sql = """
            SELECT pg_catalog.pg_get_userbyid(t.typowner)::text
            FROM pg_type t
            JOIN pg_namespace n ON n.oid = t.typnamespace
            WHERE n.nspname = $1 AND t.typname = $2
            LIMIT 1
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [
                client.bind(schema),
                client.bind(name)
            ])
            for row in rows { return try row.decode(String?.self) }
            return nil
        }
    }

    /// Fetch the comment for a user-defined type.
    func fetchTypeComment(schema: String, name: String) async throws -> String? {
        let sql = """
            SELECT obj_description(t.oid, 'pg_type')
            FROM pg_type t
            JOIN pg_namespace n ON n.oid = t.typnamespace
            WHERE n.nspname = $1 AND t.typname = $2
            LIMIT 1
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [
                client.bind(schema),
                client.bind(name)
            ])
            for row in rows { return try row.decode(String?.self) }
            return nil
        }
    }
}
