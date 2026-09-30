import Foundation
import PostgresWire

/// High-level database introspection and property discovery.
public extension PostgresMetadataClient {
    /// Fetch comprehensive properties for a specific database.
    func fetchDatabaseProperties(name: String) async throws -> PostgresDatabaseProperties {
        // daticulocale was added in PostgreSQL 15 — try the full query first,
        // fall back to a query without it for older server versions.
        if let result = try? await fetchDatabasePropertiesFull(name: name) {
            return result
        }
        return try await fetchDatabasePropertiesLegacy(name: name)
    }

    /// Full query including daticulocale (PostgreSQL 15+).
    private func fetchDatabasePropertiesFull(name: String) async throws -> PostgresDatabaseProperties {
        let sql = """
            SELECT
                d.oid::text,
                d.datname,
                pg_catalog.pg_get_userbyid(d.datdba) AS owner,
                pg_catalog.pg_encoding_to_char(d.encoding) AS encoding,
                d.datcollate AS collation,
                d.datctype AS ctype,
                COALESCE(d.daticulocale, '') AS icu_locale,
                d.datconnlimit::text AS connection_limit,
                d.datistemplate::text AS is_template,
                d.datallowconn::text AS allow_connections,
                COALESCE(t.spcname, 'pg_default') AS tablespace,
                pg_catalog.pg_database_size(d.datname)::text AS size_bytes,
                (SELECT count(*)::text FROM pg_catalog.pg_stat_activity WHERE datname = d.datname) AS active_connections,
                COALESCE(pg_catalog.shobj_description(d.oid, 'pg_database'), '') AS description,
                COALESCE(d.datacl::text, '') AS acl
            FROM pg_catalog.pg_database d
            LEFT JOIN pg_catalog.pg_tablespace t ON t.oid = d.dattablespace
            WHERE d.datname = \(client.quoteLiteral(name))
            """

        let rows = try await client.simpleQuery(sql)
        var props: PostgresDatabaseProperties?
        for try await v in rows.decode((String, String, String, String, String, String, String, String, String, String, String, String, String, String, String).self) {
            props = PostgresDatabaseProperties(
                oid: v.0, name: v.1, owner: v.2, encoding: v.3, collation: v.4, ctype: v.5,
                icuLocale: v.6.isEmpty ? nil : v.6,
                connectionLimit: Int(v.7) ?? -1,
                isTemplate: v.8 == "t" || v.8 == "true",
                allowConnections: v.9 == "t" || v.9 == "true",
                tablespace: v.10,
                sizeBytes: Int64(v.11) ?? 0,
                activeConnections: Int(v.12) ?? 0,
                description: v.13.isEmpty ? nil : v.13,
                acl: v.14.isEmpty ? nil : v.14
            )
        }

        guard let result = props else {
            throw PostgresError.protocolError("Database '\(name)' not found")
        }
        return result
    }

    /// Fallback query without daticulocale (PostgreSQL < 15).
    private func fetchDatabasePropertiesLegacy(name: String) async throws -> PostgresDatabaseProperties {
        let sql = """
            SELECT
                d.oid::text,
                d.datname,
                pg_catalog.pg_get_userbyid(d.datdba) AS owner,
                pg_catalog.pg_encoding_to_char(d.encoding) AS encoding,
                d.datcollate AS collation,
                d.datctype AS ctype,
                d.datconnlimit::text AS connection_limit,
                d.datistemplate::text AS is_template,
                d.datallowconn::text AS allow_connections,
                COALESCE(t.spcname, 'pg_default') AS tablespace,
                pg_catalog.pg_database_size(d.datname)::text AS size_bytes,
                (SELECT count(*)::text FROM pg_catalog.pg_stat_activity WHERE datname = d.datname) AS active_connections,
                COALESCE(pg_catalog.shobj_description(d.oid, 'pg_database'), '') AS description,
                COALESCE(d.datacl::text, '') AS acl
            FROM pg_catalog.pg_database d
            LEFT JOIN pg_catalog.pg_tablespace t ON t.oid = d.dattablespace
            WHERE d.datname = \(client.quoteLiteral(name))
            """

        let rows = try await client.simpleQuery(sql)
        var props: PostgresDatabaseProperties?
        for try await v in rows.decode((String, String, String, String, String, String, String, String, String, String, String, String, String, String).self) {
            props = PostgresDatabaseProperties(
                oid: v.0, name: v.1, owner: v.2, encoding: v.3, collation: v.4, ctype: v.5,
                icuLocale: nil,
                connectionLimit: Int(v.6) ?? -1,
                isTemplate: v.7 == "t" || v.7 == "true",
                allowConnections: v.8 == "t" || v.8 == "true",
                tablespace: v.9,
                sizeBytes: Int64(v.10) ?? 0,
                activeConnections: Int(v.11) ?? 0,
                description: v.12.isEmpty ? nil : v.12,
                acl: v.13.isEmpty ? nil : v.13
            )
        }

        guard let result = props else {
            throw PostgresError.protocolError("Database '\(name)' not found")
        }
        return result
    }

    /// Fetch database-level configuration parameters.
    func fetchDatabaseParameters(databaseOid: String) async throws -> [PostgresDatabaseParameter] {
        let sql = """
            SELECT unnest(setconfig)::text AS setting
            FROM pg_catalog.pg_db_role_setting
            WHERE setdatabase = \(databaseOid)::oid AND setrole = 0
            """
        var params: [PostgresDatabaseParameter] = []
        let rows = try await client.simpleQuery(sql)
        for try await setting in rows.decode(String.self) {
            let parts = setting.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                params.append(PostgresDatabaseParameter(name: String(parts[0]), value: String(parts[1])))
            }
        }
        return params
    }

    /// List all available tablespaces.
    func listTablespaces() async throws -> [String] {
        var names: [String] = []
        let rows = try await client.simpleQuery("SELECT spcname FROM pg_catalog.pg_tablespace ORDER BY spcname")
        for try await name in rows.decode(String.self) { names.append(name) }
        return names
    }

    /// Fetch all server settings configurable at the database level.
    func fetchDatabaseConfigurableSettings() async throws -> [PostgresSettingDefinition] {
        let sql = """
            SELECT name, vartype,
                   coalesce(min_val, ''), coalesce(max_val, ''),
                   coalesce(enumvals::text, ''),
                   coalesce(boot_val, ''), coalesce(unit, ''),
                   coalesce(short_desc, ''), context, category
            FROM pg_catalog.pg_settings
            WHERE context IN ('user', 'superuser')
            ORDER BY category, name
            """
        var results: [PostgresSettingDefinition] = []
        let rows = try await client.simpleQuery(sql)
        for try await v in rows.decode((String, String, String, String, String, String, String, String, String, String).self) {
            let enumVals: [String]
            if !v.4.isEmpty {
                let trimmed = v.4.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                enumVals = trimmed.split(separator: ",").map { String($0) }
            } else {
                enumVals = []
            }
            results.append(PostgresSettingDefinition(
                name: v.0, vartype: v.1, minVal: v.2, maxVal: v.3,
                enumVals: enumVals, bootVal: v.5, unit: v.6,
                shortDesc: v.7, context: v.8, category: v.9
            ))
        }
        return results
    }

    /// Fetch default privileges from `pg_default_acl`.
    func fetchDefaultPrivileges() async throws -> [PostgresDefaultPrivilege] {
        let sql = """
            SELECT
                COALESCE(n.nspname, '') AS schema_name,
                pg_catalog.pg_get_userbyid(d.defaclrole) AS owner,
                d.defaclobjtype::text,
                COALESCE(d.defaclacl::text, '') AS acl
            FROM pg_catalog.pg_default_acl d
            LEFT JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
            ORDER BY schema_name, owner
            """

        var results: [PostgresDefaultPrivilege] = []
        let rows = try await client.simpleQuery(sql)
        for try await v in rows.decode((String, String, String, String).self) {
            let objectType = mapDefaclObjType(v.2)
            let entries = PostgresACLEntry.parse(acl: v.3)
            for entry in entries {
                results.append(PostgresDefaultPrivilege(
                    schema: v.0, owner: v.1, objectType: objectType,
                    grantee: entry.grantee, privileges: entry.privileges
                ))
            }
        }
        return results
    }

    /// Map `defaclobjtype` character to `PostgresObjectType`.
    private func mapDefaclObjType(_ code: String) -> PostgresObjectType {
        switch code {
        case "r": return .tables
        case "S": return .sequences
        case "f": return .functions
        case "T": return .types
        case "n": return .schemas
        default: return .tables
        }
    }

    /// List available character encodings.
    func listEncodings() async throws -> [String] {
        let sql = """
            SELECT pg_catalog.pg_encoding_to_char(i) AS encoding
            FROM generate_series(0, 100) i
            WHERE pg_catalog.pg_encoding_to_char(i) <> ''
            ORDER BY encoding
            """
        var names: [String] = []
        let rows = try await client.simpleQuery(sql)
        for try await name in rows.decode(String.self) { names.append(name) }
        return names
    }

    /// List available collations.
    func listCollations() async throws -> [String] {
        let sql = """
            SELECT collname
            FROM pg_catalog.pg_collation
            WHERE collencoding = -1 OR collencoding = (SELECT encoding FROM pg_catalog.pg_database WHERE datname = current_database())
            ORDER BY collname
            """
        var names: [String] = []
        let rows = try await client.simpleQuery(sql)
        for try await name in rows.decode(String.self) { names.append(name) }
        return names
    }

    /// List template databases.
    func listDatabaseTemplates() async throws -> [String] {
        let sql = "SELECT datname FROM pg_catalog.pg_database WHERE datistemplate = true ORDER BY datname"
        var names: [String] = []
        let rows = try await client.simpleQuery(sql)
        for try await name in rows.decode(String.self) { names.append(name) }
        return names
    }

    /// Generate a `CREATE DATABASE` SQL statement from properties.
    func generateCreateDatabaseSQL(
        props: PostgresDatabaseProperties,
        params: [PostgresDatabaseParameter]
    ) -> String {
        var sql = "CREATE DATABASE \(quoteIdentifier(props.name))"
        var options: [String] = []

        options.append("    OWNER = \(quoteIdentifier(props.owner))")
        options.append("    ENCODING = \(PostgresQuoting.quoteLiteral(props.encoding))")
        options.append("    LC_COLLATE = \(PostgresQuoting.quoteLiteral(props.collation))")
        options.append("    LC_CTYPE = \(PostgresQuoting.quoteLiteral(props.ctype))")
        if let icu = props.icuLocale {
            options.append("    ICU_LOCALE = \(PostgresQuoting.quoteLiteral(icu))")
        }
        options.append("    TABLESPACE = \(quoteIdentifier(props.tablespace))")
        if props.connectionLimit != -1 {
            options.append("    CONNECTION LIMIT = \(props.connectionLimit)")
        }
        if props.isTemplate {
            options.append("    IS_TEMPLATE = true")
        }
        if !props.allowConnections {
            options.append("    ALLOW_CONNECTIONS = false")
        }

        sql += "\n    WITH\n" + options.joined(separator: "\n") + ";"

        if let desc = props.description, !desc.isEmpty {
            sql += "\n\nCOMMENT ON DATABASE \(quoteIdentifier(props.name)) IS \(PostgresQuoting.quoteLiteral(desc));"
        }

        for param in params {
            sql += "\n\nALTER DATABASE \(quoteIdentifier(props.name)) SET \(quoteIdentifier(param.name)) = \(PostgresQuoting.quoteLiteral(param.value));"
        }

        return sql
    }

    private func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

