
/// Detailed sequence introspection for the sequence editor.
public extension PostgresMetadataClient {

    /// Fetch detailed metadata for a sequence including all properties.
    func sequenceDetails(schema: String, name: String) async throws -> PostgresSequenceDetails? {
        // Use pg_sequences catalog view (available PG 10+) — avoids direct sequence query
        // which can fail for sequences the user doesn't have USAGE on.
        let sql = """
            SELECT
                ps.start_value::text,
                ps.increment::text,
                ps.min_value::text,
                ps.max_value::text,
                ps.cache_size::text,
                ps.cycle::text,
                ps.last_value::text,
                pg_catalog.pg_get_userbyid(c.relowner)::text AS owner,
                obj_description(c.oid, 'pg_class')::text AS comment
            FROM pg_sequences ps
            JOIN pg_class c ON c.relname = ps.sequencename AND c.relkind = 'S'
            JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = ps.schemaname
            WHERE ps.schemaname = $1 AND ps.sequencename = $2
            LIMIT 1
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [
                client.bind(schema),
                client.bind(name)
            ])
            for row in rows {
                let (startValue, increment, minValue, maxValue, cache, cycleStr, lastValue, owner, comment)
                    = try row.decode((String?, String?, String?, String?, String?, String?, String?, String?, String?).self)
                return PostgresSequenceDetails(
                    name: name, schema: schema,
                    startValue: startValue ?? "1",
                    incrementBy: increment ?? "1",
                    minValue: minValue ?? "",
                    maxValue: maxValue ?? "",
                    cache: cache ?? "1",
                    isCycling: cycleStr == "true" || cycleStr == "t",
                    lastValue: lastValue,
                    owner: owner ?? "",
                    comment: comment
                )
            }
            return nil
        }
    }

    /// Fetch the comment for a sequence.
    func fetchSequenceComment(schema: String, name: String) async throws -> String? {
        let sql = """
            SELECT obj_description(c.oid, 'pg_class')
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'S'
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

/// Detailed metadata for a PostgreSQL sequence.
public struct PostgresSequenceDetails: Sendable {
    public let name: String
    public let schema: String
    public let startValue: String
    public let incrementBy: String
    public let minValue: String
    public let maxValue: String
    public let cache: String
    public let isCycling: Bool
    public let lastValue: String?
    public let owner: String
    public let comment: String?

    public init(
        name: String, schema: String, startValue: String, incrementBy: String,
        minValue: String, maxValue: String, cache: String, isCycling: Bool,
        lastValue: String?, owner: String, comment: String?
    ) {
        self.name = name; self.schema = schema; self.startValue = startValue
        self.incrementBy = incrementBy; self.minValue = minValue; self.maxValue = maxValue
        self.cache = cache; self.isCycling = isCycling; self.lastValue = lastValue
        self.owner = owner; self.comment = comment
    }
}
