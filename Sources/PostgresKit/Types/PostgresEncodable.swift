import Foundation

/// A Swift value that can be sent as a statement parameter.
public protocol PostgresEncodable {
    func postgresBind() throws -> PostgresBind
}

/// An `Encodable` value sent as `jsonb`.
public protocol JSONBEncodable: Encodable, PostgresEncodable {}

extension JSONBEncodable {
    public func postgresBind() throws -> PostgresBind {
        .json(String(decoding: try JSONEncoder().encode(self), as: UTF8.self))
    }
}

extension String: PostgresEncodable { public func postgresBind() -> PostgresBind { .text(self) } }
extension Int: PostgresEncodable { public func postgresBind() -> PostgresBind { .int(self) } }
extension Int32: PostgresEncodable { public func postgresBind() -> PostgresBind { .int32(self) } }
extension Int64: PostgresEncodable { public func postgresBind() -> PostgresBind { .int(Int(self)) } }
extension Double: PostgresEncodable { public func postgresBind() -> PostgresBind { .double(self) } }
extension Bool: PostgresEncodable { public func postgresBind() -> PostgresBind { .bool(self) } }
extension UUID: PostgresEncodable { public func postgresBind() -> PostgresBind { .uuid(self) } }
extension Date: PostgresEncodable { public func postgresBind() -> PostgresBind { .timestamp(self) } }
extension Data: PostgresEncodable { public func postgresBind() -> PostgresBind { .bytes(self) } }
extension Decimal: PostgresEncodable { public func postgresBind() -> PostgresBind { .decimal(self) } }

extension Optional: PostgresEncodable where Wrapped: PostgresEncodable {
    public func postgresBind() throws -> PostgresBind {
        switch self {
        case .some(let value): try value.postgresBind()
        case .none: .null
        }
    }
}

extension Array: PostgresEncodable where Element: Encodable {
    /// Strings, integers and UUIDs as PostgreSQL arrays; anything else as `jsonb`.
    public func postgresBind() throws -> PostgresBind {
        if let strings = self as? [String] { return .array(strings, arrayTypeOID: 1009) }
        if let ints = self as? [Int] { return .array(ints.map(String.init), arrayTypeOID: 1016) }
        if let uuids = self as? [UUID] { return .array(uuids.map { $0.uuidString.lowercased() }, arrayTypeOID: 2951) }
        return .json(String(decoding: try JSONEncoder().encode(self), as: UTF8.self))
    }
}
