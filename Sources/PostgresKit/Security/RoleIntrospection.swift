import Foundation

/// High-level role introspection.
public extension PostgresSecurityClient {
    /// List all non-system roles with their attributes.
    func listRoles() async throws -> [PostgresRoleInfo] {
        let sql = """
            SELECT
                r.rolname, r.rolsuper, r.rolcreaterole, r.rolcreatedb,
                r.rolcanlogin, r.rolreplication, r.rolinherit,
                r.rolconnlimit::text, r.rolvaliduntil::text,
                r.rolbypassrls, r.oid::text
            FROM pg_catalog.pg_roles r
            WHERE r.rolname !~ '^pg_'
            ORDER BY r.rolname
            """
        var results: [PostgresRoleInfo] = []
        let rows = try await client.simpleQuery(sql)
        for try await v in rows.decode((String, Bool, Bool, Bool, Bool, Bool, Bool, String, String?, Bool, String).self) {
            results.append(PostgresRoleInfo(
                oid: v.10, name: v.0, isSuperuser: v.1,
                canCreateRole: v.2, canCreateDB: v.3,
                canLogin: v.4, isReplication: v.5,
                inherit: v.6, bypassRLS: v.9,
                connectionLimit: Int(v.7) ?? -1, validUntil: v.8
            ))
        }
        return results
    }

    /// Fetch role-level configuration parameters.
    func fetchRoleParameters(roleOid: String) async throws -> [PostgresDatabaseParameter] {
        let sql = """
            SELECT unnest(setconfig)::text AS setting
            FROM pg_catalog.pg_db_role_setting
            WHERE setrole = \(roleOid)::oid AND setdatabase = 0
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

    /// Fetch all server settings configurable at the role level.
    func fetchRoleConfigurableSettings() async throws -> [PostgresSettingDefinition] {
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

    /// Fetch security labels for a role.
    func fetchRoleSecurityLabels(role: String) async throws -> [PostgresSecurityLabel] {
        let sql = """
            SELECT provider, label
            FROM pg_catalog.pg_shseclabel sl
            JOIN pg_catalog.pg_roles r ON sl.objoid = r.oid
            WHERE r.rolname = \(client.quoteLiteral(role))
            ORDER BY provider
            """
        var results: [PostgresSecurityLabel] = []
        let rows = try await client.simpleQuery(sql)
        for try await v in rows.decode((String, String).self) {
            results.append(PostgresSecurityLabel(provider: v.0, label: v.1))
        }
        return results
    }

    /// List roles that the specified role belongs to.
    func listMemberOf(role: String) async throws -> [PostgresRoleMembership] {
        let sql = """
            SELECT r.rolname, m.rolname, am.admin_option,
                   COALESCE(am.inherit_option, true),
                   COALESCE(am.set_option, true)
            FROM pg_catalog.pg_auth_members am
            JOIN pg_catalog.pg_roles r ON am.roleid = r.oid
            JOIN pg_catalog.pg_roles m ON am.member = m.oid
            WHERE m.rolname = \(client.quoteLiteral(role))
            ORDER BY r.rolname
            """
        var results: [PostgresRoleMembership] = []
        let rows = try await client.simpleQuery(sql)
        for try await v in rows.decode((String, String, Bool, Bool, Bool).self) {
            results.append(PostgresRoleMembership(
                roleName: v.0, memberName: v.1,
                adminOption: v.2, inheritOption: v.3, setOption: v.4
            ))
        }
        return results
    }

    /// List members of the specified role.
    func listMembers(of role: String) async throws -> [PostgresRoleMembership] {
        let sql = """
            SELECT r.rolname, m.rolname, am.admin_option,
                   COALESCE(am.inherit_option, true),
                   COALESCE(am.set_option, true)
            FROM pg_catalog.pg_auth_members am
            JOIN pg_catalog.pg_roles r ON am.roleid = r.oid
            JOIN pg_catalog.pg_roles m ON am.member = m.oid
            WHERE r.rolname = \(client.quoteLiteral(role))
            ORDER BY m.rolname
            """
        var results: [PostgresRoleMembership] = []
        let rows = try await client.simpleQuery(sql)
        for try await v in rows.decode((String, String, Bool, Bool, Bool).self) {
            results.append(PostgresRoleMembership(
                roleName: v.0, memberName: v.1,
                adminOption: v.2, inheritOption: v.3, setOption: v.4
            ))
        }
        return results
    }

    /// Fetch the comment on a role.
    func fetchRoleComment(role: String) async throws -> String? {
        let sql = """
            SELECT d.description
            FROM pg_catalog.pg_shdescription d
            JOIN pg_catalog.pg_authid a ON a.oid = d.objoid
            WHERE d.classoid = 'pg_catalog.pg_authid'::regclass
              AND a.rolname = \(client.quoteLiteral(role))
            """
        let rows = try await client.simpleQuery(sql)
        for try await v in rows.decode(String.self) { return v }
        return nil
    }

    /// Returns the current role's effective permissions in a single query.
    ///
    /// Uses `pg_roles` for role attributes and `has_database_privilege()` for
    /// database-level checks. Works on PostgreSQL 12+.
    func currentPermissions() async throws -> PostgresPermissions {
        let sql = """
            SELECT
                r.rolsuper, r.rolcreaterole, r.rolcreatedb,
                r.rolcanlogin, r.rolreplication, r.rolbypassrls,
                has_database_privilege(current_user, current_database(), 'CREATE') AS can_create_in_db
            FROM pg_catalog.pg_roles r
            WHERE r.rolname = current_user
            """
        let rows = try await client.simpleQuery(sql)
        for try await v in rows.decode((Bool, Bool, Bool, Bool, Bool, Bool, Bool).self) {
            return PostgresPermissions(
                isSuperuser: v.0,
                canCreateRole: v.1,
                canCreateDB: v.2,
                canLogin: v.3,
                isReplication: v.4,
                bypassRLS: v.5,
                canCreateInCurrentDB: v.6
            )
        }
        return PostgresPermissions(
            isSuperuser: false, canCreateRole: false, canCreateDB: false,
            canLogin: true, isReplication: false, bypassRLS: false,
            canCreateInCurrentDB: false
        )
    }
}
