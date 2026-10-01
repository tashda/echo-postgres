import Foundation
import Logging

public struct PostgresNotification: Sendable, Equatable {
    public let channel: String
    public let payload: String?
    public let pid: Int32?
}

/// LISTEN/NOTIFY fan-out for a ``PostgresClient``.
///
/// Holds its client weakly (the client owns the notifier). While ``listen(channels:)`` is active the
/// listening task keeps the client alive; call ``stop()`` to release it.
public actor PostgresNotifier {
    private weak var client: PostgresClient?
    private let logger: Logger
    private var listeningTask: Task<Void, Never>?
    public typealias Handler = @Sendable (PostgresNotification) -> Void
    private var handlers: [String: [Handler]] = [:] // channel -> handlers
    // AsyncStream continuations per channel
    private struct StreamEntry: Sendable, Equatable {
        let id: UUID
        let continuation: AsyncStream<PostgresNotification>.Continuation
        static func == (lhs: StreamEntry, rhs: StreamEntry) -> Bool { lhs.id == rhs.id }
    }
    private var streams: [String: [StreamEntry]] = [:]
    private var channels: Set<String> = []

    public init(client: PostgresClient, logger: Logger) {
        self.client = client
        self.logger = logger
    }

    private func requireClient() throws -> PostgresClient {
        guard let client else { throw PostgresError(message: "The PostgresClient of this notifier has been released") }
        return client
    }

    public func notify(channel: String, payload: String? = nil) async throws {
        let client = try requireClient()
        let sql: String
        if let payload {
            sql = "NOTIFY \(quoteIdent(channel)), \(PostgresQuoting.quoteLiteral(payload))"
        } else {
            sql = "NOTIFY \(quoteIdent(channel))"
        }
        _ = try await client.executeDDL(sql)
    }

    /// Listens on `channels` on a connection of its own, which waits on its socket while idle and
    /// listens again after a reconnect.
    public func listen(channels: [String]) async throws {
        listeningTask?.cancel()
        listeningTask = nil
        self.channels = Set(channels.map { $0.lowercased() })
        let client = try requireClient()
        let pool = client.pool
        let listened = Array(self.channels)
        listeningTask = Task(name: "postgres-notifier") { [weak self, logger] in
            while !Task.isCancelled {
                var lease: PostgresLease?
                do {
                    let opened = try await pool.open()
                    lease = opened
                    for channel in listened {
                        _ = try await opened.connection.execute("LISTEN \(Self.quote(channel))")
                    }
                    while !Task.isCancelled {
                        for note in try await opened.connection.waitWhileIdle() {
                            await self?.deliver(channel: note.channel, payload: note.payload, pid: note.pid)
                        }
                    }
                } catch is CancellationError {
                    // stopped
                } catch {
                    logger.warning("Listen loop error on channels \(listened): \(String(describing: error))")
                }
                await lease?.connection.close()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    public func stop() {
        listeningTask?.cancel()
        listeningTask = nil
    }

    public func registerHandler(for channel: String, handler: @escaping Handler) {
        let key = channel.lowercased()
        handlers[key, default: []].append(handler)
    }

    public func removeHandlers(for channel: String) {
        handlers[channel.lowercased()] = []
    }

    public func unlisten(channel: String) async throws {
        let key = channel.lowercased()
        channels.remove(key)
        handlers[key] = []
        if let list = streams.removeValue(forKey: key) {
            list.forEach { $0.continuation.finish() }
        }
        // Listen again on the remaining channels (a new LISTEN connection).
        if channels.isEmpty { stop() } else { try await listen(channels: Array(channels)) }
    }

    // Subscribe to notifications for a given channel as an AsyncStream
    public func notifications(for channel: String) -> AsyncStream<PostgresNotification> {
        let key = channel.lowercased()
        return AsyncStream { continuation in
            let entry = StreamEntry(id: UUID(), continuation: continuation)
            streams[key, default: []].append(entry)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStream(id: entry.id, for: key) }
            }
        }
    }

    // Bridge for the wire layer to deliver a notification
    public func deliver(channel: String, payload: String?, pid: Int32?) {
        let key = channel.lowercased()
        let note = PostgresNotification(channel: key, payload: payload, pid: pid)
        if let list = handlers[key] {
            list.forEach { $0(note) }
        }
        if let entries = streams[key] {
            entries.forEach { $0.continuation.yield(note) }
        }
    }

    private func removeStream(id: UUID, for key: String) {
        guard var list = streams[key] else { return }
        list.removeAll { $0.id == id }
        streams[key] = list
    }

    private func quoteIdent(_ s: String) -> String { Self.quote(s) }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
