
/// High-level COMMENT operations for database objects.
public extension PostgresAdminClient {
    /// Set or clear the comment on a table.
    @discardableResult
    func addTableComment(name: String, comment: String?) async throws -> Int {
        let commentSQL = comment.map { client.quoteLiteral($0) } ?? "NULL"
        return try await client.executeDDL("COMMENT ON TABLE \(client.quoteIdentifier(name)) IS \(commentSQL)")
    }

    /// Set or clear the comment on a column.
    @discardableResult
    func addColumnComment(table: String, column: String, comment: String?) async throws -> Int {
        let commentSQL = comment.map { client.quoteLiteral($0) } ?? "NULL"
        return try await client.executeDDL("COMMENT ON COLUMN \(client.quoteIdentifier(table)).\(client.quoteIdentifier(column)) IS \(commentSQL)")
    }

    /// Set or clear the comment on an index.
    @discardableResult
    func addIndexComment(name: String, comment: String?) async throws -> Int {
        let commentSQL = comment.map { client.quoteLiteral($0) } ?? "NULL"
        return try await client.executeDDL("COMMENT ON INDEX \(client.quoteIdentifier(name)) IS \(commentSQL)")
    }

    /// Set or clear the comment on a constraint.
    @discardableResult
    func addConstraintComment(name: String, table: String, comment: String?) async throws -> Int {
        let commentSQL = comment.map { client.quoteLiteral($0) } ?? "NULL"
        return try await client.executeDDL("COMMENT ON CONSTRAINT \(client.quoteIdentifier(name)) ON \(client.quoteIdentifier(table)) IS \(commentSQL)")
    }

    /// Set or clear the comment on a function.
    @discardableResult
    func addFunctionComment(name: String, parameters: String = "", comment: String?) async throws -> Int {
        let commentSQL = comment.map { client.quoteLiteral($0) } ?? "NULL"
        return try await client.executeDDL("COMMENT ON FUNCTION \(client.quoteIdentifier(name))(\(parameters)) IS \(commentSQL)")
    }

    /// Set or clear the comment on a trigger.
    @discardableResult
    func addTriggerComment(name: String, table: String, comment: String?) async throws -> Int {
        let commentSQL = comment.map { client.quoteLiteral($0) } ?? "NULL"
        return try await client.executeDDL("COMMENT ON TRIGGER \(client.quoteIdentifier(name)) ON \(client.quoteIdentifier(table)) IS \(commentSQL)")
    }

    /// Set or clear the comment on a schema.
    @discardableResult
    func addSchemaComment(name: String, comment: String?) async throws -> Int {
        let commentSQL = comment.map { client.quoteLiteral($0) } ?? "NULL"
        return try await client.executeDDL("COMMENT ON SCHEMA \(client.quoteIdentifier(name)) IS \(commentSQL)")
    }

    /// Set or clear the comment on a view.
    @discardableResult
    func addViewComment(name: String, comment: String?) async throws -> Int {
        let commentSQL = comment.map { client.quoteLiteral($0) } ?? "NULL"
        return try await client.executeDDL("COMMENT ON VIEW \(client.quoteIdentifier(name)) IS \(commentSQL)")
    }

    /// Set or clear the comment on a sequence.
    @discardableResult
    func addSequenceComment(name: String, comment: String?) async throws -> Int {
        let commentSQL = comment.map { client.quoteLiteral($0) } ?? "NULL"
        return try await client.executeDDL("COMMENT ON SEQUENCE \(client.quoteIdentifier(name)) IS \(commentSQL)")
    }

    /// Set or clear the comment on an extension.
    @discardableResult
    func addExtensionComment(name: String, comment: String?) async throws -> Int {
        let commentSQL = comment.map { client.quoteLiteral($0) } ?? "NULL"
        return try await client.executeDDL("COMMENT ON EXTENSION \(client.quoteIdentifier(name)) IS \(commentSQL)")
    }

    /// Set or clear the comment on a type.
    @discardableResult
    func addTypeComment(name: String, comment: String?) async throws -> Int {
        let commentSQL = comment.map { client.quoteLiteral($0) } ?? "NULL"
        return try await client.executeDDL("COMMENT ON TYPE \(client.quoteIdentifier(name)) IS \(commentSQL)")
    }
}
