import PostgresWire
import Foundation

import NIOConcurrencyHelpers

/// Small least-recently-used cache. Thread-safe; lookups and updates are O(capacity), which is fine
/// for the small capacities it is used with.
public final class LRUCache<Key: Hashable, Value>: @unchecked Sendable {
    private var values: [Key: Value] = [:]
    /// Least recently used first.
    private var order: [Key] = []
    private let capacity: Int
    private let lock = NIOLock()

    public init(capacity: Int) {
        precondition(capacity > 0, "LRU capacity must be > 0")
        self.capacity = capacity
    }

    public func get(_ key: Key) -> Value? {
        lock.withLock {
            guard let value = values[key] else { return nil }
            touch(key)
            return value
        }
    }

    public func set(_ key: Key, value: Value) {
        lock.withLock {
            if values.updateValue(value, forKey: key) != nil {
                touch(key)
                return
            }
            order.append(key)
            while order.count > capacity {
                values.removeValue(forKey: order.removeFirst())
            }
        }
    }

    public func remove(_ key: Key) {
        lock.withLock {
            guard values.removeValue(forKey: key) != nil else { return }
            if let index = order.firstIndex(of: key) { order.remove(at: index) }
        }
    }

    public var count: Int { lock.withLock { values.count } }

    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}

public struct PreparedStatementInfo: Sendable {
    public let sql: String
    public let parameterCount: Int
    public let handle: WireConnection.WirePreparedStatement
    public init(sql: String, parameterCount: Int, handle: WireConnection.WirePreparedStatement) {
        self.sql = sql
        self.parameterCount = parameterCount
        self.handle = handle
    }
}

/// Per-connection record of statements that were run with binds.
///
/// PostgresNIO sends bound queries as unnamed statements (parsed on every execution), so this holds
/// metadata only; server-side prepared statements live in ``PreparedServerCache``.
public final class StatementCache: @unchecked Sendable {
    private let lru: LRUCache<String, PreparedStatementInfo>

    public init(capacity: Int = 256) {
        self.lru = LRUCache(capacity: capacity)
    }

    private func key(sql: String, parameterCount: Int) -> String {
        "\(sql)|#\(parameterCount)"
    }

    public func lookup(sql: String, parameterCount: Int) -> PreparedStatementInfo? {
        lru.get(key(sql: sql, parameterCount: parameterCount))
    }

    public func insert(_ info: PreparedStatementInfo) {
        lru.set(key(sql: info.sql, parameterCount: info.parameterCount), value: info)
    }

    public func remove(sql: String, parameterCount: Int) {
        let k = key(sql: sql, parameterCount: parameterCount)
        lru.remove(k)
    }
}
