#if canImport(CLibpq)
internal import CLibpq
#else
internal import CLibpqSystem
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
/// libpq connection keywords and values, passed as arrays (`PQconnectStartParams`), never as a
/// conninfo string: no quoting rules to get wrong, and the password never sits in a string that
/// could be logged.
public struct PGConnectionParameters: Sendable, Equatable, CustomStringConvertible {
    public private(set) var entries: [(keyword: String, value: String)] = []

    public init() {}

    public init(_ entries: KeyValuePairs<String, String>) {
        for (keyword, value) in entries { set(keyword, value) }
    }

    /// Sets a keyword, replacing an earlier value.
    public mutating func set(_ keyword: String, _ value: String?) {
        entries.removeAll { $0.keyword == keyword }
        if let value { entries.append((keyword, value)) }
    }

    public subscript(keyword: String) -> String? {
        entries.first { $0.keyword == keyword }?.value
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entries.elementsEqual(rhs.entries) { $0.keyword == $1.keyword && $0.value == $1.value }
    }

    /// For logs: every keyword, with the password and key password hidden.
    public var description: String {
        entries.map { entry in
            let hidden = ["password", "sslpassword"].contains(entry.keyword)
            return "\(entry.keyword)=\(hidden ? "***" : entry.value)"
        }.joined(separator: " ")
    }

    /// Calls `body` with NULL-terminated C arrays of keywords and values.
    func withCArrays<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>, UnsafePointer<UnsafePointer<CChar>?>) throws -> R) rethrows -> R {
        let count = entries.count
        let keywords = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: count + 1)
        let values = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: count + 1)
        for (index, entry) in entries.enumerated() {
            keywords[index] = UnsafePointer(strdup(entry.keyword))
            values[index] = UnsafePointer(strdup(entry.value))
        }
        keywords[count] = nil
        values[count] = nil
        defer {
            for index in 0..<count {
                free(UnsafeMutableRawPointer(mutating: keywords[index]))
                // The password is overwritten before the memory is released.
                if let value = values[index] {
                    memset(UnsafeMutableRawPointer(mutating: value), 0, strlen(value))
                    free(UnsafeMutableRawPointer(mutating: value))
                }
            }
            keywords.deallocate()
            values.deallocate()
        }
        return try body(keywords, values)
    }
}
