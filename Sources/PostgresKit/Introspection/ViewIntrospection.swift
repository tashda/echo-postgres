
/// Detailed view and materialized view introspection.
public extension PostgresMetadataClient {

    /// Fetch detailed metadata for a regular view.
    func viewDetails(schema: String, view: String) async throws -> PostgresViewDetails? {
        let sql = """
            SELECT
                v.viewname::text,
                v.viewowner::text,
                v.definition::text,
                obj_description(c.oid, 'pg_class')::text AS comment
            FROM pg_views v
            JOIN pg_class c ON c.relname = v.viewname AND c.relkind = 'v'
            JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = v.schemaname
            WHERE v.schemaname = $1 AND v.viewname = $2
            LIMIT 1
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [
                client.bind(schema),
                client.bind(view)
            ])
            for row in rows {
                let (name, owner, definition, comment) = try row.decode((String, String, String, String?).self)
                return PostgresViewDetails(name: name, schema: schema, owner: owner, definition: definition, comment: comment)
            }
            return nil
        }
    }

    /// Fetch detailed metadata for a materialized view.
    func materializedViewDetails(schema: String, view: String) async throws -> PostgresViewDetails? {
        let sql = """
            SELECT
                m.matviewname::text,
                m.matviewowner::text,
                m.definition::text,
                obj_description(c.oid, 'pg_class')::text AS comment,
                m.ispopulated
            FROM pg_matviews m
            JOIN pg_class c ON c.relname = m.matviewname AND c.relkind = 'm'
            JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = m.schemaname
            WHERE m.schemaname = $1 AND m.matviewname = $2
            LIMIT 1
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [
                client.bind(schema),
                client.bind(view)
            ])
            for row in rows {
                let (name, owner, definition, comment, populated) = try row.decode((String, String, String, String?, Bool).self)
                return PostgresViewDetails(name: name, schema: schema, owner: owner, definition: definition, comment: comment,
                                           isPopulated: populated)
            }
            return nil
        }
    }

    /// Fetch the comment for a view or materialized view.
    func fetchViewComment(schema: String, view: String, isMaterialized: Bool = false) async throws -> String? {
        let relkind = isMaterialized ? "m" : "v"
        let sql = """
            SELECT obj_description(c.oid, 'pg_class')
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = $3
            LIMIT 1
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [
                client.bind(schema),
                client.bind(view),
                client.bind(relkind)
            ])
            for row in rows { return try row.decode(String?.self) }
            return nil
        }
    }
}

/// Detailed metadata for a PostgreSQL view or materialized view.
public struct PostgresViewDetails: Sendable {
    public let name: String
    public let schema: String
    public let owner: String
    public let definition: String
    public let comment: String?
    /// Materialized views only: false after `WITH NO DATA` until the first refresh. Nil for views.
    public let isPopulated: Bool?

    public init(name: String, schema: String, owner: String, definition: String, comment: String?, isPopulated: Bool? = nil) {
        self.name = name
        self.schema = schema
        self.owner = owner
        self.definition = definition
        self.comment = comment
        self.isPopulated = isPopulated
    }
}
