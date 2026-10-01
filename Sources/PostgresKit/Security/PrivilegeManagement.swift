import PostgresWire

/// High-level Privilege and Role Grant management.
public extension PostgresSecurityClient {
    /// Grant specified privileges on a table to a user or role.
    @discardableResult
    ///
    /// With `columns`, the privileges apply to those columns only (`GRANT SELECT (a, b) ON ...`).
    func grantPrivileges(
        privileges: [PostgresPrivilege],
        onTable: String,
        schema: String? = nil,
        columns: [String]? = nil,
        to: String,
        withGrantOption: Bool = false,
        cascade: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["GRANT"]
        parts.append(client.privilegeList(privileges, columns: columns))
        parts.append("ON TABLE \(client.quoteQualified(onTable, schema: schema))")
        parts.append("TO \(client.quoteGrantee(to))")
        if withGrantOption { parts.append("WITH GRANT OPTION") }
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Revoke specified privileges on a table from a user or role.
    @discardableResult
    func revokePrivileges(
        privileges: [PostgresPrivilege],
        onTable: String,
        schema: String? = nil,
        columns: [String]? = nil,
        from: String,
        grantOption: Bool = false,
        cascade: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["REVOKE"]
        if grantOption { parts.append("GRANT OPTION FOR") }
        parts.append(client.privilegeList(privileges, columns: columns))
        parts.append("ON TABLE \(client.quoteQualified(onTable, schema: schema))")
        parts.append("FROM \(client.quoteGrantee(from))")
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Grant membership in a role to a user or another role.
    @discardableResult
    func grantRole(
        role: String,
        to: String,
        admin: Bool = false,
        inherit: Bool? = nil,
        set: Bool? = nil
    ) async throws -> Int {
        var parts: [String] = ["GRANT \(client.quoteIdentifier(role))"]
        parts.append("TO \(client.quoteGrantee(to))")
        // INHERIT and SET options need PostgreSQL 16+; they are only sent when given.
        var options: [String] = []
        if admin { options.append("ADMIN TRUE") }
        if let inherit { options.append("INHERIT \(inherit ? "TRUE" : "FALSE")") }
        if let set { options.append("SET \(set ? "TRUE" : "FALSE")") }
        if options == ["ADMIN TRUE"] {
            parts.append("WITH ADMIN OPTION")
        } else if !options.isEmpty {
            parts.append("WITH \(options.joined(separator: ", "))")
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Revoke membership in a role from a user or another role.
    @discardableResult
    func revokeRole(role: String, from: String, admin: Bool = false) async throws -> Int {
        var parts: [String] = ["REVOKE"]
        if admin { parts.append("ADMIN OPTION FOR") }
        parts.append("\(client.quoteIdentifier(role))")
        parts.append("FROM \(client.quoteGrantee(from))")
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Grant privileges on a schema to a user or role.
    @discardableResult
    func grantSchemaPrivileges(
        privileges: [PostgresPrivilege],
        onSchema: String,
        to: String,
        withGrantOption: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["GRANT"]
        parts.append(privileges.map { $0.rawValue }.joined(separator: ", "))
        parts.append("ON SCHEMA \(client.quoteIdentifier(onSchema))")
        parts.append("TO \(client.quoteGrantee(to))")
        if withGrantOption { parts.append("WITH GRANT OPTION") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Revoke privileges on a schema from a user or role.
    @discardableResult
    func revokeSchemaPrivileges(
        privileges: [PostgresPrivilege],
        onSchema: String,
        from: String,
        cascade: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["REVOKE"]
        parts.append(privileges.map { $0.rawValue }.joined(separator: ", "))
        parts.append("ON SCHEMA \(client.quoteIdentifier(onSchema))")
        parts.append("FROM \(client.quoteGrantee(from))")
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Grant privileges on a database to a user or role.
    @discardableResult
    func grantDatabasePrivileges(
        privileges: [PostgresPrivilege],
        onDatabase: String,
        to: String,
        withGrantOption: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["GRANT"]
        parts.append(privileges.map { $0.rawValue }.joined(separator: ", "))
        parts.append("ON DATABASE \(client.quoteIdentifier(onDatabase))")
        parts.append("TO \(client.quoteGrantee(to))")
        if withGrantOption { parts.append("WITH GRANT OPTION") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Revoke privileges on a database from a user or role.
    @discardableResult
    func revokeDatabasePrivileges(
        privileges: [PostgresPrivilege],
        onDatabase: String,
        from: String,
        cascade: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["REVOKE"]
        parts.append(privileges.map { $0.rawValue }.joined(separator: ", "))
        parts.append("ON DATABASE \(client.quoteIdentifier(onDatabase))")
        parts.append("FROM \(client.quoteGrantee(from))")
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Alter default privileges for objects created in a schema.
    @discardableResult
    func alterDefaultPrivileges(
        schema: String,
        grant privileges: [PostgresPrivilege],
        onObjectType: PostgresObjectType = .tables,
        to: String
    ) async throws -> Int {
        let sql = "ALTER DEFAULT PRIVILEGES IN SCHEMA \(client.quoteIdentifier(schema)) GRANT \(privileges.map { $0.rawValue }.joined(separator: ", ")) ON \(onObjectType.rawValue) TO \(client.quoteGrantee(to))"
        return try await client.executeDDL(sql)
    }

    /// Revoke altered default privileges for objects created in a schema.
    @discardableResult
    func revokeDefaultPrivileges(
        schema: String,
        revoke privileges: [PostgresPrivilege],
        onObjectType: PostgresObjectType = .tables,
        from: String
    ) async throws -> Int {
        let sql = "ALTER DEFAULT PRIVILEGES IN SCHEMA \(client.quoteIdentifier(schema)) REVOKE \(privileges.map { $0.rawValue }.joined(separator: ", ")) ON \(onObjectType.rawValue) FROM \(client.quoteGrantee(from))"
        return try await client.executeDDL(sql)
    }

    /// Grant privileges on all tables in a schema.
    @discardableResult
    func grantAllTablesPrivileges(
        privileges: [PostgresPrivilege],
        inSchema: String,
        to: String,
        withGrantOption: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["GRANT"]
        parts.append(privileges.map { $0.rawValue }.joined(separator: ", "))
        parts.append("ON ALL TABLES IN SCHEMA \(client.quoteIdentifier(inSchema))")
        parts.append("TO \(client.quoteGrantee(to))")
        if withGrantOption { parts.append("WITH GRANT OPTION") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Revoke privileges on all tables in a schema.
    @discardableResult
    func revokeAllTablesPrivileges(
        privileges: [PostgresPrivilege],
        inSchema: String,
        from: String,
        cascade: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["REVOKE"]
        parts.append(privileges.map { $0.rawValue }.joined(separator: ", "))
        parts.append("ON ALL TABLES IN SCHEMA \(client.quoteIdentifier(inSchema))")
        parts.append("FROM \(client.quoteGrantee(from))")
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }
}

extension PostgresClient {
    /// `SELECT, UPDATE` or, with columns, `SELECT ("a", "b"), UPDATE ("a", "b")`.
    internal func privilegeList(_ privileges: [PostgresPrivilege], columns: [String]?) -> String {
        guard let columns, !columns.isEmpty else { return privileges.map(\.rawValue).joined(separator: ", ") }
        let columnList = "(\(columns.map(quoteIdentifier).joined(separator: ", ")))"
        return privileges.map { "\($0.rawValue) \(columnList)" }.joined(separator: ", ")
    }
}
