
/// Database maintenance operations.
public extension PostgresMaintenanceClient {
    /// Perform a VACUUM operation.
    @discardableResult
    func vacuum(
        schema: String? = nil,
        table: String? = nil,
        analyze: Bool = false,
        full: Bool = false,
        verbose: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["VACUUM"]
        if full { parts.append("FULL") }
        if analyze { parts.append("ANALYZE") }
        if verbose { parts.append("VERBOSE") }
        if let table {
            if let schema { parts.append("\(client.quoteIdentifier(schema)).\(client.quoteIdentifier(table))") }
            else { parts.append(client.quoteIdentifier(table)) }
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Perform an ANALYZE operation.
    @discardableResult
    func analyze(
        schema: String? = nil,
        table: String? = nil,
        verbose: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["ANALYZE"]
        if verbose { parts.append("VERBOSE") }
        if let table {
            if let schema { parts.append("\(client.quoteIdentifier(schema)).\(client.quoteIdentifier(table))") }
            else { parts.append(client.quoteIdentifier(table)) }
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Perform a REINDEX operation.
    @discardableResult
    func reindex(
        database: String? = nil,
        schema: String? = nil,
        table: String? = nil,
        index: String? = nil,
        verbose: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["REINDEX"]
        if verbose { parts.append("(VERBOSE)") }
        if let index { parts.append("INDEX \(client.quoteIdentifier(index))") }
        else if let table {
            if let schema { parts.append("TABLE \(client.quoteIdentifier(schema)).\(client.quoteIdentifier(table))") }
            else { parts.append("TABLE \(client.quoteIdentifier(table))") }
        } else if let schema { parts.append("SCHEMA \(client.quoteIdentifier(schema))") }
        else if let database { parts.append("DATABASE \(client.quoteIdentifier(database))") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Create a new PostgreSQL extension.
    @discardableResult
    func createExtension(
        _ name: String,
        ifNotExists: Bool = true,
        schema: String? = nil,
        version: String? = nil,
        cascade: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["CREATE EXTENSION"]
        if ifNotExists { parts.append("IF NOT EXISTS") }
        parts.append(client.quoteIdentifier(name))
        if let schema { parts.append("WITH SCHEMA \(client.quoteIdentifier(schema))") }
        if let version { parts.append("VERSION \(client.quoteLiteral(version))") }
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Remove a PostgreSQL extension.
    @discardableResult
    func dropExtension(
        _ name: String,
        ifExists: Bool = true,
        cascade: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["DROP EXTENSION"]
        if ifExists { parts.append("IF NOT EXISTS") }
        parts.append(client.quoteIdentifier(name))
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Update a PostgreSQL extension to a specific version.
    @discardableResult
    func updateExtension(
        _ name: String,
        to version: String? = nil
    ) async throws -> Int {
        var parts: [String] = ["ALTER EXTENSION"]
        parts.append(client.quoteIdentifier(name))
        parts.append("UPDATE")
        if let version {
            parts.append("TO \(client.quoteLiteral(version))")
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }
}
