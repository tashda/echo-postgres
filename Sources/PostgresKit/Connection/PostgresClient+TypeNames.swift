import Foundation

extension PostgresClient {
    /// Names for types the built-in table doesn't know (extension types, enums, domains,
    /// composites), as the server writes them (`format_type`), uppercased like the built-in names.
    /// Asked once per type on a pooled connection, then cached for this client.
    public func typeNames(for oids: [UInt32]) async throws -> [UInt32: String] {
        let unknown = Set(oids.filter { PGTypeNames.name(of: $0) == nil })
        let cached = typeNameCache.withLock { cache in cache.filter { unknown.contains($0.key) } }
        let missing = unknown.subtracting(cached.keys)
        guard !missing.isEmpty else { return cached }
        let rows = try await query(
            "SELECT oid::int8, upper(format_type(oid, NULL)) FROM pg_type WHERE oid = ANY($1::oid[])",
            binds: [.array(missing.sorted().map(String.init))]
        )
        var found: [UInt32: String] = [:]
        for try await (oid, name) in rows.decode((Int64, String).self) { found[UInt32(oid)] = name }
        typeNameCache.withLock { $0.merge(found) { _, new in new } }
        return cached.merging(found) { _, new in new }
    }
}
