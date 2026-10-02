import Foundation

/// Introspection for advanced PostgreSQL object types.
public extension PostgresMetadataClient {

    // MARK: - Foreign Data Wrappers

    /// List all foreign data wrappers.
    func listForeignDataWrappers() async throws -> [PostgresFDWInfo] {
        let sql = """
            SELECT
                fdw.fdwname::text AS name,
                CASE WHEN fdw.fdwhandler = 0 THEN NULL ELSE hdl.proname::text END AS handler,
                CASE WHEN fdw.fdwvalidator = 0 THEN NULL ELSE val.proname::text END AS validator,
                r.rolname::text AS owner,
                pg_catalog.array_to_string(fdw.fdwoptions, ',')::text AS options
            FROM pg_foreign_data_wrapper fdw
            JOIN pg_roles r ON r.oid = fdw.fdwowner
            LEFT JOIN pg_proc hdl ON hdl.oid = fdw.fdwhandler
            LEFT JOIN pg_proc val ON val.oid = fdw.fdwvalidator
            ORDER BY fdw.fdwname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresFDWInfo] = []
            for row in rows {
                let (name, handler, validator, owner, optionsStr) =
                    try row.decode((String, String?, String?, String, String?).self)
                let options = optionsStr.flatMap { str in
                    str.isEmpty ? nil : str.split(separator: ",").map(String.init)
                }
                out.append(PostgresFDWInfo(name: name, handler: handler, validator: validator, owner: owner, options: options))
            }
            return out
        }
    }

    // MARK: - Foreign Servers

    /// List all foreign servers.
    func listForeignServers() async throws -> [PostgresForeignServerInfo] {
        let sql = """
            SELECT
                s.srvname::text AS name,
                s.srvtype::text AS type,
                s.srvversion::text AS version,
                fdw.fdwname::text AS fdw_name,
                r.rolname::text AS owner,
                pg_catalog.array_to_string(s.srvoptions, ',')::text AS options
            FROM pg_foreign_server s
            JOIN pg_foreign_data_wrapper fdw ON fdw.oid = s.srvfdw
            JOIN pg_roles r ON r.oid = s.srvowner
            ORDER BY s.srvname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresForeignServerInfo] = []
            for row in rows {
                let (name, type, version, fdwName, owner, optionsStr) =
                    try row.decode((String, String?, String?, String, String, String?).self)
                let options = optionsStr.flatMap { str in
                    str.isEmpty ? nil : str.split(separator: ",").map(String.init)
                }
                out.append(PostgresForeignServerInfo(name: name, type: type, version: version, fdwName: fdwName, owner: owner, options: options))
            }
            return out
        }
    }

    // MARK: - User Mappings

    /// List user mappings for a foreign server.
    func listUserMappings(serverName: String) async throws -> [PostgresUserMappingInfo] {
        let sql = """
            SELECT
                s.srvname::text AS server_name,
                CASE WHEN um.umuser = 0 THEN 'PUBLIC' ELSE r.rolname::text END AS user_name,
                pg_catalog.array_to_string(um.umoptions, ',')::text AS options
            FROM pg_user_mapping um
            JOIN pg_foreign_server s ON s.oid = um.umserver
            LEFT JOIN pg_roles r ON r.oid = um.umuser
            WHERE s.srvname = \(client.quoteLiteral(serverName))
            ORDER BY user_name
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresUserMappingInfo] = []
            for row in rows {
                let (srvName, userName, optionsStr) =
                    try row.decode((String, String, String?).self)
                let options = optionsStr.flatMap { str in
                    str.isEmpty ? nil : str.split(separator: ",").map(String.init)
                }
                out.append(PostgresUserMappingInfo(serverName: srvName, userName: userName, options: options))
            }
            return out
        }
    }

    // MARK: - Foreign Tables

    /// List foreign tables in a schema.
    func listForeignTables(schema: String? = nil) async throws -> [PostgresForeignTableInfo] {
        let schemaFilter: String
        if let schema {
            schemaFilter = "AND n.nspname = \(client.quoteLiteral(schema))"
        } else {
            schemaFilter = "AND n.nspname NOT IN ('pg_catalog', 'information_schema')"
        }
        let sql = """
            SELECT
                c.relname::text AS name,
                n.nspname::text AS schema,
                s.srvname::text AS server_name,
                array_agg(a.attname::text ORDER BY a.attnum)::text AS columns
            FROM pg_foreign_table ft
            JOIN pg_class c ON c.oid = ft.ftrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_foreign_server s ON s.oid = ft.ftserver
            LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
            WHERE true \(schemaFilter)
            GROUP BY c.relname, n.nspname, s.srvname
            ORDER BY n.nspname, c.relname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresForeignTableInfo] = []
            for row in rows {
                let (name, schema, serverName, columnsStr) =
                    try row.decode((String, String, String, String?).self)
                let columns: [String]
                if let columnsStr {
                    let cleaned = columnsStr.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                    columns = cleaned.isEmpty ? [] : cleaned.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                } else {
                    columns = []
                }
                out.append(PostgresForeignTableInfo(name: name, schema: schema, serverName: serverName, columns: columns))
            }
            return out
        }
    }

    // MARK: - Event Triggers

    /// List all event triggers.
    func listEventTriggers() async throws -> [PostgresEventTriggerInfo] {
        let sql = """
            SELECT
                e.evtname::text AS name,
                e.evtevent::text AS event,
                r.rolname::text AS owner,
                p.proname::text AS function,
                e.evtenabled::text AS enabled,
                e.evttags::text AS tags
            FROM pg_event_trigger e
            JOIN pg_roles r ON r.oid = e.evtowner
            JOIN pg_proc p ON p.oid = e.evtfoid
            ORDER BY e.evtname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresEventTriggerInfo] = []
            for row in rows {
                let (name, event, owner, function, enabled, tagsStr) =
                    try row.decode((String, String, String, String, String, String?).self)
                let tags: [String]?
                if let tagsStr, !tagsStr.isEmpty {
                    let cleaned = tagsStr.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                    tags = cleaned.isEmpty ? nil : cleaned.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                } else {
                    tags = nil
                }
                out.append(PostgresEventTriggerInfo(name: name, event: event, owner: owner, function: function, enabled: enabled, tags: tags))
            }
            return out
        }
    }

    // MARK: - Rules

    /// List rules, optionally filtered by schema and/or table.
    func listRules(schema: String? = nil, table: String? = nil) async throws -> [PostgresRuleInfo] {
        var conditions: [String] = []
        if let schema {
            conditions.append("n.nspname = \(client.quoteLiteral(schema))")
        } else {
            conditions.append("n.nspname NOT IN ('pg_catalog', 'information_schema')")
        }
        if let table {
            conditions.append("c.relname = \(client.quoteLiteral(table))")
        }
        let whereClause = conditions.joined(separator: " AND ")
        let sql = """
            SELECT
                r.rulename::text AS name,
                c.relname::text AS table_name,
                n.nspname::text AS schema,
                CASE r.ev_type
                    WHEN '1' THEN 'SELECT'
                    WHEN '2' THEN 'UPDATE'
                    WHEN '3' THEN 'INSERT'
                    WHEN '4' THEN 'DELETE'
                    ELSE r.ev_type::text
                END AS event,
                r.is_instead::text AS do_instead,
                pg_get_ruledef(r.oid, true)::text AS definition
            FROM pg_rewrite r
            JOIN pg_class c ON c.oid = r.ev_class
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE r.rulename <> '_RETURN' AND \(whereClause)
            ORDER BY n.nspname, c.relname, r.rulename
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresRuleInfo] = []
            for row in rows {
                let (name, tableName, schema, event, doInsteadStr, definition) =
                    try row.decode((String, String, String, String, String, String).self)
                out.append(PostgresRuleInfo(
                    name: name,
                    table: tableName,
                    schema: schema,
                    event: event,
                    doInstead: doInsteadStr == "true" || doInsteadStr == "t" || doInsteadStr == "YES",
                    definition: definition
                ))
            }
            return out
        }
    }

    // MARK: - Tablespaces

    /// List all tablespaces.
    func listTablespaces() async throws -> [PostgresTablespaceInfo] {
        let sql = """
            SELECT
                spcname::text AS name,
                r.rolname::text AS owner,
                pg_tablespace_location(t.oid)::text AS location,
                pg_catalog.array_to_string(t.spcoptions, ',')::text AS options
            FROM pg_tablespace t
            JOIN pg_roles r ON r.oid = t.spcowner
            ORDER BY spcname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresTablespaceInfo] = []
            for row in rows {
                let (name, owner, location, optionsStr) =
                    try row.decode((String, String, String, String?).self)
                let options = optionsStr.flatMap { str in
                    str.isEmpty ? nil : str.split(separator: ",").map(String.init)
                }
                out.append(PostgresTablespaceInfo(name: name, owner: owner, location: location, options: options))
            }
            return out
        }
    }
}
