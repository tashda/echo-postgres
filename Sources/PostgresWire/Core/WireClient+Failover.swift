import Foundation
import NIOConcurrencyHelpers
import PostgresNIO
import _ConnectionPoolModule
import NIOCore

/// Failover for the pool, like libpq's multi-host connection strings but also after connecting:
/// when the pool's server can't be reached, or (with `targetSessionAttributes` read-write or
/// primary) the server turns out to be read-only after a failover, the client chooses among the
/// configured hosts again and replaces the pool.
///
/// A call is retried once, only when that cannot run anything twice: no connection was made (so
/// nothing was sent), or the server rejected a single statement as read-only. Work inside
/// `withConnection` that had started is never re-run; the next call uses the new pool.
extension PostgresWireClient {
    func withFailover<T>(
        retriesReadOnlyRejection: Bool = false,
        _ operation: (PostgresClient, NIOLockedValueBox<Bool>) async throws -> T
    ) async throws -> T {
        let generation = pools.withLockedValue { $0.generation }
        let entered = NIOLockedValueBox(false)
        do {
            return try await operation(try await pool(), entered)
        } catch {
            let started = entered.withLockedValue { $0 }
            let unreachable = !started && Self.isUnreachable(error)
            let readOnly = demandsWritableServer && Self.isReadOnlyRejection(error)
            guard unreachable || readOnly else { throw error }
            try await failOver(from: generation, after: error)
            guard unreachable || (readOnly && retriesReadOnlyRejection) else { throw error }
            return try await operation(try await pool(), NIOLockedValueBox(false))
        }
    }

    /// Whether the configured hosts could offer another server: several hosts, or an attribute
    /// that a server can stop satisfying (a primary demoted to standby).
    var demandsWritableServer: Bool {
        configuration.targetSessionAttributes == .readWrite || configuration.targetSessionAttributes == .primary
    }

    /// The pool could not make a connection: nothing was sent. That includes a server that answers
    /// the connection with 57P03 (starting up, in recovery, shutting down).
    static func isUnreachable(_ error: any Error) -> Bool {
        if let poolError = error as? ConnectionPoolError { return poolError == .connectionCreationCircuitBreakerTripped }
        if let psql = error as? PSQLError {
            return psql.code == .connectionError || psql.serverInfo?[.sqlState] == "57P03"
        }
        return false
    }

    /// The server refused the statement because it is read-only (SQLSTATE 25006), as a demoted
    /// primary does.
    static func isReadOnlyRejection(_ error: any Error) -> Bool {
        (error as? PostgresServerErrorCode)?.serverSQLState == "25006"
    }

    /// Chooses the host again and replaces the pool, once for all calls that saw the same pool fail.
    func failOver(from generation: Int, after error: any Error) async throws {
        let task = failoverTask.withLockedValue { box -> Task<Void, any Error>? in
            guard pools.withLockedValue({ $0.generation }) == generation else { return nil } // already replaced
            if let running = box { return running }
            let started = Task { try await self.replacePoolWithReselectedHost(after: error) }
            box = started
            return started
        }
        guard let task else { return }
        defer { failoverTask.withLockedValue { $0 = nil } }
        try await task.value
    }

    private func replacePoolWithReselectedHost(after error: any Error) async throws {
        let previous = resolvedConfiguration
        let opened: PostgresOpenedConnection
        do {
            opened = try await Self.openSelectedConnection(configuration: configuration, logger: logger)
        } catch {
            throw PostgresServerUnreachableError(previous: previous, underlying: error)
        }
        try? await opened.connection.close()
        var replacement = try Self.makePool(opened.configuration, expiresAt: opened.credential.expiresAt, logger: logger)
        let retired = pools.withLockedValue { box -> Pool in
            let old = box
            replacement.generation = old.generation + 1
            box = replacement
            return old
        }
        current.withLockedValue { $0 = opened.configuration }
        let from = "\(previous.host):\(previous.port)", to = "\(opened.configuration.host):\(opened.configuration.port)"
        logger.warning("Failed over from \(from) to \(to) after: \(String(describing: error))")
        let change = PostgresHostChange(
            from: PostgresHost(host: previous.host, port: previous.port),
            to: PostgresHost(host: opened.configuration.host, port: opened.configuration.port),
            reason: PostgresServerUnreachableError(previous: previous, underlying: error).errorDescription ?? String(describing: error),
            date: Date())
        for observer in hostObservers.withLockedValue({ Array($0.values) }) { observer.yield(change) }
        // Leases on the retired pool fail by themselves; give running work a moment, then stop it.
        Task.detached {
            try? await Task.sleep(for: .seconds(30))
            retired.runTask.cancel()
        }
    }
}

extension PostgresWireClient {
    /// The server the pool is connected to now.
    public var currentHost: PostgresHost {
        let configuration = resolvedConfiguration
        return PostgresHost(host: configuration.unixSocketPath ?? configuration.host, port: configuration.port)
    }

    /// Reports each time the pool fails over to another server (see ``currentHost``). Each call
    /// returns a new stream; it ends when the listener stops iterating.
    public func hostChanges() -> AsyncStream<PostgresHostChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PostgresHostChange>.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuation.onTermination = { [weak self] _ in
            _ = self?.hostObservers.withLockedValue { $0.removeValue(forKey: id) }
        }
        hostObservers.withLockedValue { $0[id] = continuation }
        return stream
    }
}

/// The pool moved from one server to another after its server went away or turned read-only.
public struct PostgresHostChange: Sendable, Equatable {
    public let from: PostgresHost
    public let to: PostgresHost
    /// Why: the error that made the pool choose again, in words.
    public let reason: String
    public let date: Date
}

/// The pool's server went away and no configured host can be reached now.
public struct PostgresServerUnreachableError: Error, LocalizedError, @unchecked Sendable {
    public let host: String
    public let port: Int
    public let underlying: any Error

    init(previous: PostgresWireConfiguration, underlying: any Error) {
        host = previous.unixSocketPath ?? previous.host
        port = previous.port
        self.underlying = underlying
    }

    public var errorDescription: String? {
        "Can't reach the server at \(host):\(port) any more: it may have stopped, or the network is down. (\(Self.describe(underlying)))"
    }

    private static func describe(_ error: any Error) -> String {
        if let io = error as? IOError { return String(cString: strerror(io.errnoCode)) }
        if let selection = error as? PostgresHostSelectionError { return selection.localizedDescription }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// An error that carries the server's SQLSTATE, whichever layer wrapped it (PostgresNIO's
/// `PSQLError`, PostgresKit's `PostgresError`), so failover can tell what the server said.
public protocol PostgresServerErrorCode: Error {
    var serverSQLState: String? { get }
}

extension PSQLError: PostgresServerErrorCode {
    public var serverSQLState: String? { serverInfo?[.sqlState] }
}

/// PostgresNIO's older `PostgresError` (thrown by the future-based query API, which
/// `WireConnection.queryResult` uses for the command tag).
extension PostgresNIO.PostgresError: PostgresServerErrorCode {
    public var serverSQLState: String? {
        if case .server(let message) = self { return message.fields[.sqlState] }
        return nil
    }
}
