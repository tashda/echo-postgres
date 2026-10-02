import Foundation
import PGLibpq

/// One `$n` parameter of a statement: text the server parses as the parameter's type, bytes
/// (`bytea`), or NULL. `typeOID` 0 lets the server infer the type from the statement.
public struct PostgresBind: Sendable, Equatable {
    public let parameter: PGParameter

    public init(_ parameter: PGParameter) { self.parameter = parameter }

    public static let null = PostgresBind(.null)
    public static func text(_ value: String, typeOID: UInt32 = 0) -> PostgresBind { PostgresBind(.text(value, typeOID: typeOID)) }
    public static func bytes(_ value: Data) -> PostgresBind { PostgresBind(.binary(value)) }
    public static func bool(_ value: Bool) -> PostgresBind { .text(value ? "t" : "f", typeOID: 16) }
    public static func int(_ value: Int) -> PostgresBind { .text(String(value), typeOID: 20) }
    public static func int32(_ value: Int32) -> PostgresBind { .text(String(value), typeOID: 23) }
    public static func double(_ value: Double) -> PostgresBind { .text(PostgresBind.text(of: value), typeOID: 701) }
    public static func decimal(_ value: Decimal) -> PostgresBind { .text(value.description, typeOID: 1700) }
    public static func uuid(_ value: UUID) -> PostgresBind { .text(value.uuidString.lowercased(), typeOID: 2950) }
    /// A point in time, as `timestamptz` (ISO 8601 with offset, microseconds).
    public static func timestamp(_ value: Date) -> PostgresBind { .text(PostgresDateText.format(value), typeOID: 1184) }
    public static func json(_ text: String) -> PostgresBind { .text(text, typeOID: 3802) }
    /// An array as a PostgreSQL array literal of text elements; `elementTypeOID` names the array
    /// type to send (0 lets the server infer it).
    public static func array(_ elements: [String?], arrayTypeOID: UInt32 = 0) -> PostgresBind {
        .text(PostgresArrayLiteral.make(elements), typeOID: arrayTypeOID)
    }

    static func text(of value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
        return "\(value)"
    }
}

/// Text array literals (`{"a","b\\"c",NULL}`), both ways.
enum PostgresArrayLiteral {
    /// The elements of a one-dimensional array literal; nil elements are SQL NULL. Nil when the text
    /// isn't an array literal (or is multi-dimensional). A leading `[1:3]=` bound is skipped.
    static func parse(_ text: String) -> [String?]? {
        var characters = Substring(text)
        if characters.first == "[", let equals = characters.firstIndex(of: "=") {
            characters = characters[characters.index(after: equals)...]
        }
        guard characters.first == "{", characters.last == "}" else { return nil }
        let body = characters.dropFirst().dropLast()
        if body.isEmpty { return [] }
        var elements: [String?] = []
        var current = ""
        var quoted = false, wasQuoted = false, escaped = false
        for character in body {
            if escaped { current.append(character); escaped = false; continue }
            switch character {
            case "\\" where quoted: escaped = true
            case "\"": quoted.toggle(); wasQuoted = true
            case "{" where !quoted: return nil
            case "," where !quoted:
                elements.append(!wasQuoted && current == "NULL" ? nil : current)
                current = ""; wasQuoted = false
            default: current.append(character)
            }
        }
        elements.append(!wasQuoted && current == "NULL" ? nil : current)
        return elements
    }

    static func make(_ elements: [String?]) -> String {
        "{" + elements.map { element in
            guard let element else { return "NULL" }
            var quoted = "\""
            for character in element {
                if character == "\"" || character == "\\" { quoted.append("\\") }
                quoted.append(character)
            }
            return quoted + "\""
        }.joined(separator: ",") + "}"
    }
}
