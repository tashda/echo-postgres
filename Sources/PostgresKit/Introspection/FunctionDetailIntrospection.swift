
/// Detailed function introspection for the function editor.
public extension PostgresMetadataClient {

    /// Fetch detailed metadata for a function, including parameters, language, and all attributes.
    func functionDetails(schema: String, name: String) async throws -> PostgresFunctionDetails? {
        let sql = """
            SELECT
                p.proname::text,
                pg_catalog.pg_get_function_result(p.oid)::text AS return_type,
                l.lanname::text AS language,
                p.prosrc::text AS source,
                p.provolatile::text,
                p.proparallel::text,
                p.prosecdef::text,
                p.proisstrict::text,
                p.procost::text,
                p.prorows::text,
                pg_catalog.pg_get_function_arguments(p.oid)::text AS arguments,
                obj_description(p.oid, 'pg_proc')::text AS comment
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            JOIN pg_language l ON l.oid = p.prolang
            WHERE n.nspname = $1 AND p.proname = $2
            ORDER BY p.oid LIMIT 1
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [
                client.bind(schema),
                client.bind(name)
            ])
            for row in rows {
                let (proname, returnType, language, source, volatile, parallel, secdef, strict, cost, estRows, arguments, comment)
                    = try row.decode((String, String, String, String, String, String, String, String, String, String, String, String?).self)
                return PostgresFunctionDetails(
                    name: proname, schema: schema,
                    returnType: returnType, language: language, source: source,
                    volatility: volatile, parallelSafety: parallel,
                    isSecurityDefiner: secdef == "true" || secdef == "t",
                    isStrict: strict == "true" || strict == "t",
                    cost: cost, estimatedRows: estRows,
                    arguments: arguments, comment: comment
                )
            }
            return nil
        }
    }
}

/// Detailed metadata for a PostgreSQL function.
public struct PostgresFunctionDetails: Sendable {
    public let name: String
    public let schema: String
    public let returnType: String
    public let language: String
    public let source: String
    /// Raw volatility character: "v" (volatile), "s" (stable), "i" (immutable)
    public let volatility: String
    /// Raw parallel safety character: "u" (unsafe), "r" (restricted), "s" (safe)
    public let parallelSafety: String
    public let isSecurityDefiner: Bool
    public let isStrict: Bool
    public let cost: String
    public let estimatedRows: String
    /// Raw argument string from pg_get_function_arguments() — caller parses into individual parameters.
    public let arguments: String
    public let comment: String?

    public init(
        name: String, schema: String, returnType: String, language: String, source: String,
        volatility: String, parallelSafety: String, isSecurityDefiner: Bool, isStrict: Bool,
        cost: String, estimatedRows: String, arguments: String, comment: String?
    ) {
        self.name = name; self.schema = schema; self.returnType = returnType
        self.language = language; self.source = source; self.volatility = volatility
        self.parallelSafety = parallelSafety; self.isSecurityDefiner = isSecurityDefiner
        self.isStrict = isStrict; self.cost = cost; self.estimatedRows = estimatedRows
        self.arguments = arguments; self.comment = comment
    }
}
