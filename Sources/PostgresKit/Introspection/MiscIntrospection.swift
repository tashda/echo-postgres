import Foundation

/// Introspection for aggregates, operators, languages, and casts.
public extension PostgresMetadataClient {

    // MARK: - Aggregates

    /// List aggregate functions in a schema.
    func listAggregates(schema: String) async throws -> [PostgresAggregateInfo] {
        let sql = """
            SELECT
                p.proname::text AS name,
                n.nspname::text AS schema,
                pg_catalog.format_type(a.aggtranstype, NULL)::text AS state_type,
                t.proname::text AS state_function,
                a.agginitval::text AS initial_value,
                COALESCE(pg_catalog.format_type(p.proargtypes[0], NULL), '*')::text AS input_type
            FROM pg_aggregate a
            JOIN pg_proc p ON p.oid = a.aggfnoid
            JOIN pg_namespace n ON n.oid = p.pronamespace
            JOIN pg_proc t ON t.oid = a.aggtransfn
            WHERE n.nspname = \(client.quoteLiteral(schema))
            ORDER BY p.proname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresAggregateInfo] = []
            for row in rows {
                let (name, schemaName, stateType, stateFunc, initVal, inputType) =
                    try row.decode((String, String, String, String, String?, String).self)
                out.append(PostgresAggregateInfo(
                    name: name, schema: schemaName, inputType: inputType,
                    stateType: stateType, stateFunction: stateFunc, initialValue: initVal
                ))
            }
            return out
        }
    }

    // MARK: - Operators

    /// List operators in a schema.
    func listOperators(schema: String) async throws -> [PostgresOperatorInfo] {
        let sql = """
            SELECT
                o.oprname::text AS name,
                n.nspname::text AS schema,
                CASE WHEN o.oprleft = 0 THEN NULL ELSE pg_catalog.format_type(o.oprleft, NULL)::text END AS left_type,
                CASE WHEN o.oprright = 0 THEN NULL ELSE pg_catalog.format_type(o.oprright, NULL)::text END AS right_type,
                pg_catalog.format_type(o.oprresult, NULL)::text AS result_type,
                p.proname::text AS procedure
            FROM pg_operator o
            JOIN pg_namespace n ON n.oid = o.oprnamespace
            JOIN pg_proc p ON p.oid = o.oprcode
            WHERE n.nspname = \(client.quoteLiteral(schema))
            ORDER BY o.oprname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresOperatorInfo] = []
            for row in rows {
                let (name, schemaName, leftType, rightType, resultType, procedure) =
                    try row.decode((String, String, String?, String?, String, String).self)
                out.append(PostgresOperatorInfo(
                    name: name, schema: schemaName,
                    leftType: leftType, rightType: rightType,
                    resultType: resultType, procedure: procedure
                ))
            }
            return out
        }
    }

    // MARK: - Languages

    /// List procedural languages.
    func listLanguages() async throws -> [PostgresLanguageInfo] {
        let sql = """
            SELECT
                l.lanname::text AS name,
                r.rolname::text AS owner,
                l.lanispl::text AS is_pl,
                l.lanpltrusted::text AS is_trusted
            FROM pg_language l
            JOIN pg_roles r ON r.oid = l.lanowner
            ORDER BY l.lanname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresLanguageInfo] = []
            for row in rows {
                let (name, owner, isPlStr, isTrustedStr) =
                    try row.decode((String, String, String, String).self)
                out.append(PostgresLanguageInfo(
                    name: name, owner: owner,
                    isPL: isPlStr == "true" || isPlStr == "t",
                    isTrusted: isTrustedStr == "true" || isTrustedStr == "t"
                ))
            }
            return out
        }
    }

    // MARK: - Casts

    /// List type casts.
    func listCasts() async throws -> [PostgresCastInfo] {
        let sql = """
            SELECT
                pg_catalog.format_type(c.castsource, NULL)::text AS source_type,
                pg_catalog.format_type(c.casttarget, NULL)::text AS target_type,
                CASE WHEN c.castfunc = 0 THEN NULL ELSE p.proname::text END AS function,
                CASE c.castcontext
                    WHEN 'e' THEN 'explicit'
                    WHEN 'a' THEN 'assignment'
                    WHEN 'i' THEN 'implicit'
                    ELSE c.castcontext::text
                END AS context
            FROM pg_cast c
            LEFT JOIN pg_proc p ON p.oid = c.castfunc
            ORDER BY source_type, target_type
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresCastInfo] = []
            for row in rows {
                let (sourceType, targetType, function, context) =
                    try row.decode((String, String, String?, String).self)
                out.append(PostgresCastInfo(
                    sourceType: sourceType, targetType: targetType,
                    function: function, context: context
                ))
            }
            return out
        }
    }
}
