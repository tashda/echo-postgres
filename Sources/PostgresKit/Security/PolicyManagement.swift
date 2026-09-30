import PostgresWire

/// Row Level Security (RLS) policy management.
public extension PostgresSecurityClient {
    /// Enable row level security on a table.
    @discardableResult
    func enableRowLevelSecurity(table: String) async throws -> Int {
        return try await client.executeDDL("ALTER TABLE \(client.quoteIdentifier(table)) ENABLE ROW LEVEL SECURITY")
    }

    /// Disable row level security on a table.
    @discardableResult
    func disableRowLevelSecurity(table: String) async throws -> Int {
        return try await client.executeDDL("ALTER TABLE \(client.quoteIdentifier(table)) DISABLE ROW LEVEL SECURITY")
    }

    /// Force row level security for the table owner.
    @discardableResult
    func forceRowLevelSecurity(table: String) async throws -> Int {
        return try await client.executeDDL("ALTER TABLE \(client.quoteIdentifier(table)) FORCE ROW LEVEL SECURITY")
    }

    /// Remove forced row level security for the table owner.
    @discardableResult
    func noForceRowLevelSecurity(table: String) async throws -> Int {
        return try await client.executeDDL("ALTER TABLE \(client.quoteIdentifier(table)) NO FORCE ROW LEVEL SECURITY")
    }

    /// Create a row level security policy.
    @discardableResult
    func createPolicy(
        name: String,
        table: String,
        schema: String? = nil,
        command: PostgresPolicyCommand = .all,
        to: [String]? = nil,
        using: String? = nil,
        withCheck: String? = nil,
        permissive: Bool = true
    ) async throws -> Int {
        var parts: [String] = ["CREATE POLICY \(client.quoteIdentifier(name))"]
        parts.append("ON \(client.quoteQualified(table, schema: schema))")
        if !permissive { parts.append("AS RESTRICTIVE") }
        parts.append("FOR \(command.rawValue)")
        if let to, !to.isEmpty {
            parts.append("TO \(to.map(client.quoteGrantee).joined(separator: ", "))")
        }
        if let using {
            parts.append("USING (\(using))")
        }
        if let withCheck {
            parts.append("WITH CHECK (\(withCheck))")
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Drop a row level security policy.
    @discardableResult
    func dropPolicy(
        name: String,
        table: String,
        ifExists: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["DROP POLICY"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        parts.append("ON \(client.quoteIdentifier(table))")
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Alter an existing row level security policy.
    @discardableResult
    func alterPolicy(
        name: String,
        table: String,
        to: [String]? = nil,
        using: String? = nil,
        withCheck: String? = nil
    ) async throws -> Int {
        var parts: [String] = ["ALTER POLICY \(client.quoteIdentifier(name))"]
        parts.append("ON \(client.quoteIdentifier(table))")
        if let to, !to.isEmpty {
            parts.append("TO \(to.map(client.quoteIdentifier).joined(separator: ", "))")
        }
        if let using {
            parts.append("USING (\(using))")
        }
        if let withCheck {
            parts.append("WITH CHECK (\(withCheck))")
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }
}

/// The command type a policy applies to.
public enum PostgresPolicyCommand: String, Sendable {
    case all = "ALL"
    case select = "SELECT"
    case insert = "INSERT"
    case update = "UPDATE"
    case delete = "DELETE"
}
