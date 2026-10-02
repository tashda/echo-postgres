
/// Detailed trigger introspection for the trigger editor.
public extension PostgresMetadataClient {

    /// Fetch detailed metadata for a specific trigger on a table.
    func triggerDetails(schema: String, table: String, name: String) async throws -> PostgresTriggerDetails? {
        let sql = """
            SELECT
                t.tgname::text,
                pg_catalog.pg_get_triggerdef(t.oid)::text AS definition,
                t.tgenabled::text,
                p.proname::text AS function_name,
                n2.nspname::text AS function_schema,
                obj_description(t.oid, 'pg_trigger')::text AS comment
            FROM pg_trigger t
            JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_proc p ON p.oid = t.tgfoid
            JOIN pg_namespace n2 ON n2.oid = p.pronamespace
            WHERE n.nspname = $1 AND c.relname = $2 AND t.tgname = $3
              AND NOT t.tgisinternal
            LIMIT 1
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [
                client.bind(schema),
                client.bind(table),
                client.bind(name)
            ])
            for row in rows {
                let (triggerName, definition, enabledFlag, funcName, funcSchema, comment)
                    = try row.decode((String, String, String, String, String, String?).self)
                return PostgresTriggerDetails(
                    name: triggerName, schema: schema, table: table,
                    definition: definition,
                    enabledFlag: enabledFlag,
                    functionName: funcName,
                    functionSchema: funcSchema,
                    comment: comment
                )
            }
            return nil
        }
    }
}

/// Detailed metadata for a PostgreSQL trigger.
public struct PostgresTriggerDetails: Sendable {
    public let name: String
    public let schema: String
    public let table: String
    /// Full trigger definition from pg_get_triggerdef() — contains timing, events, FOR EACH, WHEN, EXECUTE FUNCTION.
    public let definition: String
    /// tgenabled flag: "O" (origin), "D" (disabled), "R" (replica), "A" (always)
    public let enabledFlag: String
    public let functionName: String
    public let functionSchema: String
    public let comment: String?

    public var isEnabled: Bool { enabledFlag == "O" }

    public init(
        name: String, schema: String, table: String, definition: String,
        enabledFlag: String, functionName: String, functionSchema: String, comment: String?
    ) {
        self.name = name; self.schema = schema; self.table = table
        self.definition = definition; self.enabledFlag = enabledFlag
        self.functionName = functionName; self.functionSchema = functionSchema
        self.comment = comment
    }
}
