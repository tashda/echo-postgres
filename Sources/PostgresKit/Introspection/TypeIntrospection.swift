
/// User-defined type discovery.
public extension PostgresTypeClient {
    /// List user-defined types (enums, composites, ranges, domains) in a schema.
    func listTypes(schema: String) async throws -> [PostgresTypeInfo] {
        let sql = """
            SELECT t.typname,
                   CASE t.typtype
                       WHEN 'e' THEN 'enum'
                       WHEN 'c' THEN 'composite'
                       WHEN 'r' THEN 'range'
                       WHEN 'd' THEN 'domain'
                       ELSE t.typtype::text
                   END AS type_kind
            FROM pg_type t
            JOIN pg_namespace n ON t.typnamespace = n.oid
            WHERE n.nspname = $1
              AND t.typtype IN ('e', 'c', 'r', 'd')
              AND t.typname NOT LIKE E'\\\\_%'
            ORDER BY t.typname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema)])
            return try rows.map { row in
                let (name, kind) = try row.decode((String, String).self)
                return PostgresTypeInfo(name: name, schema: schema, kind: kind)
            }
        }
    }
}
