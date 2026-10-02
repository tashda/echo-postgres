
/// Stored procedure discovery.
public extension PostgresMetadataClient {
    /// List stored procedures in a schema (PG 11+).
    func listProcedures(schema: String) async throws -> [String] {
        let sql = """
            SELECT p.proname
            FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = $1 AND p.prokind = 'p'
            ORDER BY p.proname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema)])
            return try rows.map { try $0.decode(String.self) }
        }
    }
}
