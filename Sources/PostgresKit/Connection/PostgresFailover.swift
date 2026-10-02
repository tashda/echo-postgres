import Foundation

/// The pool moved from one server to another after its server went away or turned read-only.
public struct PostgresHostChange: Sendable, Equatable {
    public let from: PostgresHost
    public let to: PostgresHost
    /// Why: the error that made the pool choose again, in words.
    public let reason: String
    public let date: Date
}

/// The pool's server went away and no configured host can be reached now.
public struct PostgresServerUnreachableError: Error, LocalizedError, Sendable {
    public let host: String
    public let port: Int
    /// libpq's text.
    public let reason: String

    public var errorDescription: String? {
        "Can't reach the server at \(host):\(port) any more: it may have stopped, or the network is down. (\(reason))"
    }
}

/// What connecting to one configured server found (for a connection test that checks each server).
public struct PostgresHostProbe: Sendable {
    public enum Role: String, Sendable {
        /// Not in recovery: accepts writes.
        case primary
        /// In recovery: a read-only standby.
        case standby
    }

    public let host: PostgresHost
    /// The server's role, or nil when it couldn't be reached or refused the sign-in (see ``error``).
    public let role: Role?
    public let error: PostgresError?
    /// How long connecting and asking took.
    public let elapsed: Duration
}

/// An error that carries the server's SQLSTATE.
public protocol PostgresServerErrorCode: Error {
    var serverSQLState: String? { get }
}

extension PostgresError: PostgresServerErrorCode {
    public var serverSQLState: String? { sqlState }
}
