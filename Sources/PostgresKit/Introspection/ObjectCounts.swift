import Foundation

public extension PostgresMetadataClient {
    /// The exact number of rows in a table (`count(*)`, not the planner's estimate).
    func exactRowCount(schema: String = "public", table: String) async throws -> Int64 {
        let rows = try await client.simpleQuery("SELECT count(*) FROM \(client.quoteQualified(table, schema: schema))")
        for try await count in rows.decode(Int64.self) { return count }
        return 0
    }
}

public extension PostgresTypeClient {
    /// Whether a type with this name exists in `schema`, or anywhere on the search path when nil.
    func typeExists(name: String, schema: String? = nil) async throws -> Bool {
        let schemaFilter = schema.map { "n.nspname = \(client.quoteLiteral($0))" } ?? "pg_type_is_visible(t.oid)"
        let sql = "SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE t.typname = \(client.quoteLiteral(name)) AND \(schemaFilter)"
        let rows = try await client.simpleQuery(sql)
        for try await count in rows.decode(Int64.self) { return count > 0 }
        return false
    }
}
