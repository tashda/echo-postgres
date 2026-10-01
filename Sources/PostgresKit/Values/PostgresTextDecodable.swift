import Foundation

/// A Swift type a column's text can be read as (`row.decode((String, Int?).self)`).
///
/// Values arrive as the server's text (`DateStyle=ISO`, `IntervalStyle=postgres`).
public protocol PostgresTextDecodable: SendableMetatype {
    /// Reads a non-NULL value.
    static func decode(text: String) throws -> Self
    /// Reads SQL NULL: an error, except for optionals.
    static func decodeNull() throws -> Self
}

extension PostgresTextDecodable {
    public static func decodeNull() throws -> Self {
        throw PostgresDecodingError(message: "NULL where \(Self.self) was expected")
    }
}

/// A column's text could not be read as the requested type.
public struct PostgresDecodingError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public var errorDescription: String? { message }

    static func cannotRead(_ text: String, as type: Any.Type) -> PostgresDecodingError {
        PostgresDecodingError(message: "Can't read \"\(text.prefix(80))\" as \(type)")
    }
}

extension Optional: PostgresTextDecodable where Wrapped: PostgresTextDecodable {
    public static func decode(text: String) throws -> Self { try Wrapped.decode(text: text) }
    public static func decodeNull() throws -> Self { nil }
}

extension String: PostgresTextDecodable {
    public static func decode(text: String) -> String { text }
}

extension Bool: PostgresTextDecodable {
    public static func decode(text: String) throws -> Bool {
        switch text {
        case "t", "true", "TRUE", "on", "1", "yes": return true
        case "f", "false", "FALSE", "off", "0", "no": return false
        default: throw PostgresDecodingError.cannotRead(text, as: Bool.self)
        }
    }
}

/// Integers: the server prints them in decimal.
public protocol PostgresTextDecodableInteger: FixedWidthInteger, PostgresTextDecodable {}

extension PostgresTextDecodableInteger {
    public static func decode(text: String) throws -> Self {
        guard let value = Self(text) else { throw PostgresDecodingError.cannotRead(text, as: Self.self) }
        return value
    }
}

extension Int: PostgresTextDecodableInteger {}
extension Int8: PostgresTextDecodableInteger {}
extension Int16: PostgresTextDecodableInteger {}
extension Int32: PostgresTextDecodableInteger {}
extension Int64: PostgresTextDecodableInteger {}
extension UInt32: PostgresTextDecodableInteger {}
extension UInt64: PostgresTextDecodableInteger {}

extension Double: PostgresTextDecodable {
    public static func decode(text: String) throws -> Double {
        switch text {
        case "NaN": return .nan
        case "Infinity": return .infinity
        case "-Infinity": return -.infinity
        default:
            guard let value = Double(text) else { throw PostgresDecodingError.cannotRead(text, as: Double.self) }
            return value
        }
    }
}

extension Float: PostgresTextDecodable {
    public static func decode(text: String) throws -> Float { Float(try Double.decode(text: text)) }
}

extension Decimal: PostgresTextDecodable {
    public static func decode(text: String) throws -> Decimal {
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            throw PostgresDecodingError.cannotRead(text, as: Decimal.self)
        }
        return value
    }
}

extension UUID: PostgresTextDecodable {
    public static func decode(text: String) throws -> UUID {
        guard let value = UUID(uuidString: text) else { throw PostgresDecodingError.cannotRead(text, as: UUID.self) }
        return value
    }
}

extension Date: PostgresTextDecodable {
    /// `date`, `timestamp` (read as UTC) and `timestamptz` text.
    public static func decode(text: String) throws -> Date {
        guard let value = PostgresDateText.parse(text) else { throw PostgresDecodingError.cannotRead(text, as: Date.self) }
        return value
    }
}

extension Data: PostgresTextDecodable {
    /// `bytea` in hex output (`\x0102`, the default since PostgreSQL 9.0) or escape output.
    public static func decode(text: String) throws -> Data {
        guard let value = PostgresByteaText.parse(text) else { throw PostgresDecodingError.cannotRead(text, as: Data.self) }
        return value
    }
}

extension Array: PostgresTextDecodable where Element: PostgresTextDecodable {
    /// A one-dimensional array literal (`{a,"b c",NULL}`); NULL elements need an optional element type.
    public static func decode(text: String) throws -> [Element] {
        guard let elements = PostgresArrayLiteral.parse(text) else { throw PostgresDecodingError.cannotRead(text, as: [Element].self) }
        return try elements.map { element in
            if let element { try Element.decode(text: element) } else { try Element.decodeNull() }
        }
    }
}
