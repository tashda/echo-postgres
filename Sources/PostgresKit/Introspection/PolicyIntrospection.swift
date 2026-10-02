import Foundation

/// RLS policy introspection.
public extension PostgresMetadataClient {
    /// List all RLS policies on a specific table, or all policies in a schema.
    func listPolicies(schema: String, table: String? = nil) async throws -> [PostgresPolicyInfo] {
        if let table {
            let sql = """
                SELECT
                    p.polname::text AS name,
                    c.relname::text AS table_name,
                    n.nspname::text AS schema_name,
                    CASE p.polcmd
                        WHEN 'r' THEN 'SELECT'
                        WHEN 'a' THEN 'INSERT'
                        WHEN 'w' THEN 'UPDATE'
                        WHEN 'd' THEN 'DELETE'
                        WHEN '*' THEN 'ALL'
                    END::text AS command,
                    CASE WHEN p.polpermissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END::text AS type,
                    ARRAY(SELECT rolname FROM pg_roles WHERE oid = ANY(p.polroles))::text AS roles,
                    pg_get_expr(p.polqual, p.polrelid)::text AS using_expression,
                    pg_get_expr(p.polwithcheck, p.polrelid)::text AS with_check_expression
                FROM pg_policy p
                JOIN pg_class c ON c.oid = p.polrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = $1
                  AND c.relname = $2
                ORDER BY c.relname, p.polname
                """
            return try await client.withConnection { conn in
                let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema), client.bind(table)])
                return try Self.parsePolicyRows(rows)
            }
        } else {
            let sql = """
                SELECT
                    p.polname::text AS name,
                    c.relname::text AS table_name,
                    n.nspname::text AS schema_name,
                    CASE p.polcmd
                        WHEN 'r' THEN 'SELECT'
                        WHEN 'a' THEN 'INSERT'
                        WHEN 'w' THEN 'UPDATE'
                        WHEN 'd' THEN 'DELETE'
                        WHEN '*' THEN 'ALL'
                    END::text AS command,
                    CASE WHEN p.polpermissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END::text AS type,
                    ARRAY(SELECT rolname FROM pg_roles WHERE oid = ANY(p.polroles))::text AS roles,
                    pg_get_expr(p.polqual, p.polrelid)::text AS using_expression,
                    pg_get_expr(p.polwithcheck, p.polrelid)::text AS with_check_expression
                FROM pg_policy p
                JOIN pg_class c ON c.oid = p.polrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = $1
                ORDER BY c.relname, p.polname
                """
            return try await client.withConnection { conn in
                let rows = try await conn.queryPreparedRows(sql, binds: [client.bind(schema)])
                return try Self.parsePolicyRows(rows)
            }
        }
    }

    /// Parse policy rows from prepared query results.
    private static func parsePolicyRows(_ rows: [PostgresRow]) throws -> [PostgresPolicyInfo] {
        var out: [PostgresPolicyInfo] = []
        for row in rows {
            let (name, tableName, schemaName, command, type, rolesStr, usingExpr, withCheckExpr) =
                try row.decode((String, String, String, String, String, String?, String?, String?).self)

            // Parse text array format: {role1,role2}
            var roles: [String] = []
            if let rolesStr {
                let cleaned = rolesStr.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                if !cleaned.isEmpty {
                    roles = cleaned.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                }
            }

            out.append(PostgresPolicyInfo(
                name: name,
                tableName: tableName,
                schemaName: schemaName,
                command: command,
                type: type,
                roles: roles,
                usingExpression: usingExpr,
                withCheckExpression: withCheckExpr
            ))
        }
        return out
    }
}
