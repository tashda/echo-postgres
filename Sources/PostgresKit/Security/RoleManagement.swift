
/// High-level User and Role management.
public extension PostgresSecurityClient {
    /// Create a new database user or role.
    @discardableResult
    func createUser(
        name: String,
        password: String? = nil,
        superuser: Bool = false,
        createDatabase: Bool = true,
        createRole: Bool = true,
        login: Bool = true,
        encrypted: Bool = true,
        inherit: Bool = true,
        replication: Bool = false,
        bypassRLS: Bool = false,
        validUntil: String? = nil,
        inRole: [String] = [],
        role: [String] = [],
        admin: [String] = []
    ) async throws -> Int {
        var parts: [String] = ["CREATE USER"]
        parts.append(client.quoteIdentifier(name))

        if let password {
            parts.append("WITH \(client.passwordClause(password, hash: encrypted))")
        }

        if superuser { parts.append("SUPERUSER") } else { parts.append("NOSUPERUSER") }
        if createDatabase { parts.append("CREATEDB") } else { parts.append("NOCREATEDB") }
        if createRole { parts.append("CREATEROLE") } else { parts.append("NOCREATEROLE") }
        if login { parts.append("LOGIN") } else { parts.append("NOLOGIN") }
        if inherit { parts.append("INHERIT") } else { parts.append("NOINHERIT") }
        if replication { parts.append("REPLICATION") } else { parts.append("NOREPLICATION") }
        if bypassRLS { parts.append("BYPASSRLS") } else { parts.append("NOBYPASSRLS") }

        if let validUntil { parts.append("VALID UNTIL \(client.quoteLiteral(validUntil))") }

        if !inRole.isEmpty {
            parts.append("IN ROLE \(inRole.map(client.quoteIdentifier).joined(separator: ", "))")
        }

        if !role.isEmpty {
            parts.append("ROLE \(role.map(client.quoteIdentifier).joined(separator: ", "))")
        }

        if !admin.isEmpty {
            parts.append("ADMIN \(admin.map(client.quoteIdentifier).joined(separator: ", "))")
        }

        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Drop an existing user.
    @discardableResult
    func dropUser(name: String, ifExists: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP USER"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Drop an existing role.
    @discardableResult
    func dropRole(name: String, ifExists: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP ROLE"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Create a new role (without LOGIN by default, unlike createUser).
    @discardableResult
    func createRole(
        name: String,
        password: String? = nil,
        superuser: Bool = false,
        createDatabase: Bool = false,
        createRole: Bool = false,
        login: Bool = false,
        inherit: Bool = true,
        replication: Bool = false,
        bypassRLS: Bool = false,
        connectionLimit: Int? = nil,
        validUntil: String? = nil
    ) async throws -> Int {
        var parts: [String] = ["CREATE ROLE"]
        parts.append(client.quoteIdentifier(name))

        var options: [String] = []
        if let password {
            options.append(client.passwordClause(password, hash: true))
        }
        if superuser { options.append("SUPERUSER") }
        if createDatabase { options.append("CREATEDB") }
        if createRole { options.append("CREATEROLE") }
        if login { options.append("LOGIN") } else { options.append("NOLOGIN") }
        if !inherit { options.append("NOINHERIT") }
        if replication { options.append("REPLICATION") }
        if bypassRLS { options.append("BYPASSRLS") }
        if let connectionLimit { options.append("CONNECTION LIMIT \(connectionLimit)") }
        if let validUntil { options.append("VALID UNTIL \(client.quoteLiteral(validUntil))") }

        if !options.isEmpty {
            parts.append("WITH \(options.joined(separator: " "))")
        }

        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Modify an existing user or role's attributes.
    @discardableResult
    func alterUser(
        name: String,
        password: String? = nil,
        encrypted: Bool = true,
        superuser: Bool? = nil,
        createDatabase: Bool? = nil,
        createRole: Bool? = nil,
        login: Bool? = nil,
        inherit: Bool? = nil,
        replication: Bool? = nil,
        bypassRLS: Bool? = nil,
        connectionLimit: Int? = nil,
        validUntil: String? = nil,
        rename: String? = nil
    ) async throws -> Int {
        var parts: [String] = ["ALTER USER"]

        if let rename {
            parts.append("\(client.quoteIdentifier(name)) RENAME TO \(client.quoteIdentifier(rename))")
        } else {
            parts.append(client.quoteIdentifier(name))
            if let password {
                parts.append("WITH \(client.passwordClause(password, hash: encrypted))")
            }
            if let superuser { parts.append(superuser ? "SUPERUSER" : "NOSUPERUSER") }
            if let createDatabase { parts.append(createDatabase ? "CREATEDB" : "NOCREATEDB") }
            if let createRole { parts.append(createRole ? "CREATEROLE" : "NOCREATEROLE") }
            if let login { parts.append(login ? "LOGIN" : "NOLOGIN") }
            if let inherit { parts.append(inherit ? "INHERIT" : "NOINHERIT") }
            if let replication { parts.append(replication ? "REPLICATION" : "NOREPLICATION") }
            if let bypassRLS { parts.append(bypassRLS ? "BYPASSRLS" : "NOBYPASSRLS") }
            if let connectionLimit { parts.append("CONNECTION LIMIT \(connectionLimit)") }
            if let validUntil { parts.append("VALID UNTIL \(client.quoteLiteral(validUntil))") }
        }

        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Reassign all objects owned by one role to another role.
    func reassignOwned(from oldRole: String, to newRole: String) async throws {
        let sql = "REASSIGN OWNED BY \(client.quoteIdentifier(oldRole)) TO \(client.quoteIdentifier(newRole))"
        _ = try await client.executeDDL(sql)
    }

    /// Drop all objects owned by a role.
    func dropOwned(by role: String) async throws {
        let sql = "DROP OWNED BY \(client.quoteIdentifier(role))"
        _ = try await client.executeDDL(sql)
    }

    /// Set a role-level configuration parameter.
    func alterRoleSet(role: String, parameter: String, value: String) async throws {
        let sql = "ALTER ROLE \(client.quoteIdentifier(role)) SET \(client.quoteIdentifier(parameter)) TO \(client.quoteLiteral(value))"
        _ = try await client.executeDDL(sql)
    }

    /// Reset a role-level configuration parameter.
    func alterRoleReset(role: String, parameter: String) async throws {
        let sql = "ALTER ROLE \(client.quoteIdentifier(role)) RESET \(client.quoteIdentifier(parameter))"
        _ = try await client.executeDDL(sql)
    }

    /// Set or clear the comment on a role.
    func setRoleComment(role: String, comment: String?) async throws {
        let sql: String
        if let comment, !comment.isEmpty {
            sql = "COMMENT ON ROLE \(client.quoteIdentifier(role)) IS \(client.quoteLiteral(comment))"
        } else {
            sql = "COMMENT ON ROLE \(client.quoteIdentifier(role)) IS NULL"
        }
        _ = try await client.executeDDL(sql)
    }
}
