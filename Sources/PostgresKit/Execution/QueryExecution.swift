import Logging

/// High-level query execution entry points.
public extension PostgresClient {
    /// Run SQL and return the rows of its last result set plus the command tag.
    func simpleQueryResult(_ sql: String) async throws -> PostgresQueryResult {
        try await withConnection { connection in
            try await connection.queryResult(sql)
        }
    }

    /// Run SQL and stream its rows (the connection returns to the pool when they have been read).
    func simpleQuery(_ sql: String) async throws -> PostgresRows {
        try await query(sql)
    }
}
