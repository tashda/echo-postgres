import Foundation

/// Domains, composite and range types, collations and text search objects.
public extension PostgresMetadataClient {
    // MARK: - Domains

    /// List domain types in a schema.
    func listDomains(schema: String? = nil) async throws -> [PostgresDomainInfo] {
        let schemaFilter: String
        if let schema {
            schemaFilter = "AND n.nspname = \(client.quoteLiteral(schema))"
        } else {
            schemaFilter = "AND n.nspname NOT IN ('pg_catalog', 'information_schema')"
        }
        let sql = """
            SELECT
                t.typname::text AS name,
                n.nspname::text AS schema,
                pg_catalog.format_type(t.typbasetype, t.typtypmod)::text AS data_type,
                t.typdefault::text AS default_value,
                t.typnotnull::text AS not_null
            FROM pg_type t
            JOIN pg_namespace n ON n.oid = t.typnamespace
            WHERE t.typtype = 'd' \(schemaFilter)
            ORDER BY n.nspname, t.typname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresDomainInfo] = []
            for row in rows {
                let (name, schema, dataType, defaultValue, notNullStr) =
                    try row.decode((String, String, String, String?, String).self)

                // Fetch domain constraints
                let constraintSQL = """
                    SELECT
                        conname::text AS name,
                        pg_catalog.pg_get_constraintdef(c.oid)::text AS expression
                    FROM pg_constraint c
                    JOIN pg_type t ON t.oid = c.contypid
                    JOIN pg_namespace n ON n.oid = t.typnamespace
                    WHERE t.typname = \(self.client.quoteLiteral(name))
                        AND n.nspname = \(self.client.quoteLiteral(schema))
                    ORDER BY conname
                    """
                let constraintRows = try await conn.queryPreparedRows(constraintSQL, binds: [])
                var constraints: [PostgresDomainConstraint] = []
                for cRow in constraintRows {
                    let (cName, cExpr) = try cRow.decode((String, String).self)
                    constraints.append(PostgresDomainConstraint(name: cName, expression: cExpr))
                }

                out.append(PostgresDomainInfo(
                    name: name,
                    schema: schema,
                    dataType: dataType,
                    defaultValue: defaultValue,
                    isNotNull: notNullStr == "true" || notNullStr == "t",
                    constraints: constraints
                ))
            }
            return out
        }
    }

    // MARK: - Composite Types

    /// List composite types in a schema.
    func listCompositeTypes(schema: String? = nil) async throws -> [PostgresCompositeTypeInfo] {
        let schemaFilter: String
        if let schema {
            schemaFilter = "AND n.nspname = \(client.quoteLiteral(schema))"
        } else {
            schemaFilter = "AND n.nspname NOT IN ('pg_catalog', 'information_schema')"
        }
        let sql = """
            SELECT
                t.typname::text AS name,
                n.nspname::text AS schema
            FROM pg_type t
            JOIN pg_namespace n ON n.oid = t.typnamespace
            WHERE t.typtype = 'c'
                AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.reltype = t.oid AND c.relkind IN ('r', 'v', 'm', 'f', 'p'))
                \(schemaFilter)
            ORDER BY n.nspname, t.typname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresCompositeTypeInfo] = []
            for row in rows {
                let (name, schema) = try row.decode((String, String).self)

                let attrSQL = """
                    SELECT
                        a.attname::text AS name,
                        pg_catalog.format_type(a.atttypid, a.atttypmod)::text AS data_type
                    FROM pg_attribute a
                    JOIN pg_type t ON t.typrelid = a.attrelid
                    JOIN pg_namespace n ON n.oid = t.typnamespace
                    WHERE t.typname = \(self.client.quoteLiteral(name))
                        AND n.nspname = \(self.client.quoteLiteral(schema))
                        AND a.attnum > 0
                        AND NOT a.attisdropped
                    ORDER BY a.attnum
                    """
                let attrRows = try await conn.queryPreparedRows(attrSQL, binds: [])
                var attributes: [PostgresCompositeAttribute] = []
                for aRow in attrRows {
                    let (aName, aType) = try aRow.decode((String, String).self)
                    attributes.append(PostgresCompositeAttribute(name: aName, dataType: aType))
                }

                out.append(PostgresCompositeTypeInfo(name: name, schema: schema, attributes: attributes))
            }
            return out
        }
    }

    // MARK: - Range Types

    /// List range types in a schema.
    func listRangeTypes(schema: String? = nil) async throws -> [PostgresRangeTypeInfo] {
        let schemaFilter: String
        if let schema {
            schemaFilter = "AND n.nspname = \(client.quoteLiteral(schema))"
        } else {
            schemaFilter = "AND n.nspname NOT IN ('pg_catalog', 'information_schema')"
        }
        let sql = """
            SELECT
                t.typname::text AS name,
                n.nspname::text AS schema,
                st.typname::text AS subtype,
                CASE WHEN r.rngcollation = 0 THEN NULL ELSE col.collname::text END AS collation,
                opc.opcname::text AS subtype_opclass
            FROM pg_range r
            JOIN pg_type t ON t.oid = r.rngtypid
            JOIN pg_namespace n ON n.oid = t.typnamespace
            JOIN pg_type st ON st.oid = r.rngsubtype
            LEFT JOIN pg_collation col ON col.oid = r.rngcollation
            LEFT JOIN pg_opclass opc ON opc.oid = r.rngsubopc
            WHERE true \(schemaFilter)
            ORDER BY n.nspname, t.typname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresRangeTypeInfo] = []
            for row in rows {
                let (name, schema, subtype, collation, subtypeOpClass) =
                    try row.decode((String, String, String, String?, String?).self)
                out.append(PostgresRangeTypeInfo(name: name, schema: schema, subtype: subtype, collation: collation, subtypeOpClass: subtypeOpClass))
            }
            return out
        }
    }

    // MARK: - Collations

    /// List collations in a schema.
    func listCollations(schema: String? = nil) async throws -> [PostgresCollationInfo] {
        let schemaFilter: String
        if let schema {
            schemaFilter = "AND n.nspname = \(client.quoteLiteral(schema))"
        } else {
            schemaFilter = "AND n.nspname NOT IN ('pg_catalog', 'information_schema')"
        }
        let sql = """
            SELECT
                c.collname::text AS name,
                n.nspname::text AS schema,
                CASE c.collprovider WHEN 'c' THEN 'libc' WHEN 'i' THEN 'icu' WHEN 'd' THEN 'default' ELSE c.collprovider::text END AS provider,
                COALESCE(to_jsonb(c)->>'colllocale', to_jsonb(c)->>'colliculocale') AS locale,
                c.collcollate::text AS lc_collate,
                c.collctype::text AS lc_ctype
            FROM pg_collation c
            JOIN pg_namespace n ON n.oid = c.collnamespace
            WHERE true \(schemaFilter)
            ORDER BY n.nspname, c.collname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresCollationInfo] = []
            for row in rows {
                let (name, schema, provider, locale, lcCollate, lcCtype) =
                    try row.decode((String, String, String?, String?, String?, String?).self)
                out.append(PostgresCollationInfo(name: name, schema: schema, provider: provider, locale: locale, lcCollate: lcCollate, lcCtype: lcCtype))
            }
            return out
        }
    }

    // MARK: - Text Search Configurations

    /// List text search configurations in a schema.
    func listTextSearchConfigurations(schema: String? = nil) async throws -> [PostgresFTSConfigInfo] {
        let schemaFilter: String
        if let schema {
            schemaFilter = "AND n.nspname = \(client.quoteLiteral(schema))"
        } else {
            schemaFilter = "AND n.nspname NOT IN ('pg_catalog', 'information_schema')"
        }
        let sql = """
            SELECT
                cfg.cfgname::text AS name,
                n.nspname::text AS schema,
                prs.prsname::text AS parser
            FROM pg_ts_config cfg
            JOIN pg_namespace n ON n.oid = cfg.cfgnamespace
            JOIN pg_ts_parser prs ON prs.oid = cfg.cfgparser
            WHERE true \(schemaFilter)
            ORDER BY n.nspname, cfg.cfgname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresFTSConfigInfo] = []
            for row in rows {
                let (name, schema, parser) = try row.decode((String, String, String).self)
                out.append(PostgresFTSConfigInfo(name: name, schema: schema, parser: parser))
            }
            return out
        }
    }

    // MARK: - Text Search Dictionaries

    /// List text search dictionaries in a schema.
    func listTextSearchDictionaries(schema: String? = nil) async throws -> [PostgresFTSDictionaryInfo] {
        let schemaFilter: String
        if let schema {
            schemaFilter = "AND n.nspname = \(client.quoteLiteral(schema))"
        } else {
            schemaFilter = "AND n.nspname NOT IN ('pg_catalog', 'information_schema')"
        }
        let sql = """
            SELECT
                d.dictname::text AS name,
                n.nspname::text AS schema,
                t.tmplname::text AS template
            FROM pg_ts_dict d
            JOIN pg_namespace n ON n.oid = d.dictnamespace
            JOIN pg_ts_template t ON t.oid = d.dicttemplate
            WHERE true \(schemaFilter)
            ORDER BY n.nspname, d.dictname
            """
        return try await client.withConnection { conn in
            let rows = try await conn.queryPreparedRows(sql, binds: [])
            var out: [PostgresFTSDictionaryInfo] = []
            for row in rows {
                let (name, schema, template) = try row.decode((String, String, String).self)
                out.append(PostgresFTSDictionaryInfo(name: name, schema: schema, template: template))
            }
            return out
        }
    }
}
