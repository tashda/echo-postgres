
/// Sequence discovery.
public extension PostgresMetadataClient {
    /// List all sequences in a schema.
    func listSequences(schema: String) async throws -> [PostgresSequenceInfo] {
        let sql = """
            SELECT sequence_name FROM information_schema.sequences
            WHERE sequence_schema = $1
            ORDER BY sequence_name
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema)])
            return try rows.map { row in
                let name = try row.decode(String.self)
                return PostgresSequenceInfo(name: name, schema: schema)
            }
        }
    }
}
