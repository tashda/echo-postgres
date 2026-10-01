
/// Error handling extensions for PostgresClient.
public extension PostgresClient {
    /// Execute an operation with enhanced error handling.
    /// - Parameter operation: The asynchronous operation to perform.
    /// - Returns: A Result containing the operation's success value or a PostgresError on failure.
    static func executeWithEnhancedError<T>(
        _ operation: () async throws -> T
    ) async -> Result<T, PostgresError> {
        do {
            let result = try await operation()
            return .success(result)
        } catch {
            return .failure(PostgresError.from(error))
        }
    }
}

/// Helper extensions for Results containing PostgresError.
public extension Result where Failure == PostgresError {
    /// Get a user-friendly error message.
    var errorMessage: String {
        switch self {
        case .success: return "No error"
        case .failure(let error): return error.message
        }
    }

    /// Check if the error matches a specific SQLSTATE code.
    func isSQLState(_ sqlState: String) -> Bool {
        switch self {
        case .success: return false
        case .failure(let error): return error.isSQLState(sqlState)
        }
    }

    /// Check if the error is a constraint violation.
    var isConstraintViolation: Bool {
        switch self {
        case .success: return false
        case .failure(let error): return error.isConstraintViolation
        }
    }
}
