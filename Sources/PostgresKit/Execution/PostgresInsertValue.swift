import Foundation

/// Structured insert values for cases that cannot be represented as plain bind parameters.
public enum PostgresInsertValue: @unchecked Sendable {
    case bind(any PostgresEncodable)
    case sql(String)

    public init<T: PostgresEncodable>(_ value: T) {
        self = .bind(value)
    }

    public static let null: PostgresInsertValue = .sql("NULL")
    public static let currentDate: PostgresInsertValue = .sql("CURRENT_DATE")
    public static let currentTimestamp: PostgresInsertValue = .sql("CURRENT_TIMESTAMP")

    public static func jsonbLiteral(_ json: String) -> PostgresInsertValue {
        .sql("\(quoteLiteralSQL(json))::jsonb")
    }

    public static func timestamp(_ value: String) -> PostgresInsertValue {
        .sql("\(quoteLiteralSQL(value))::timestamp")
    }

    public static func date(_ value: String) -> PostgresInsertValue {
        .sql("\(quoteLiteralSQL(value))::date")
    }

    public static func castLiteral(_ value: String, as typeName: String) -> PostgresInsertValue {
        .sql("CAST(\(quoteLiteralSQL(value)) AS \(quoteTypeNameSQL(typeName)))")
    }

    public static func inet(_ value: String) -> PostgresInsertValue {
        .sql("\(quoteLiteralSQL(value))::inet")
    }

    public static func inet(_ value: IPAddress) -> PostgresInsertValue {
        .inet(value.string)
    }

    public static func cidr(_ value: String) -> PostgresInsertValue {
        .sql("\(quoteLiteralSQL(value))::cidr")
    }

    public static func macaddr(_ value: String) -> PostgresInsertValue {
        .sql("\(quoteLiteralSQL(value))::macaddr")
    }

    public static func macaddr(_ value: MACAddress) -> PostgresInsertValue {
        .macaddr(value.string)
    }

    public static func range(_ value: String) -> PostgresInsertValue {
        .sql(quoteLiteralSQL(value))
    }

    public static func array(_ values: [String]) -> PostgresInsertValue {
        let elements = values.map(quoteLiteralSQL).joined(separator: ", ")
        return .sql("ARRAY[\(elements)]")
    }

    public static func array(_ values: [Int]) -> PostgresInsertValue {
        let elements = values.map(String.init).joined(separator: ", ")
        return .sql("ARRAY[\(elements)]")
    }

    public static func array(_ values: [Int64]) -> PostgresInsertValue {
        let elements = values.map(String.init).joined(separator: ", ")
        return .sql("ARRAY[\(elements)]")
    }

    public static func emptyArray(elementType: String) -> PostgresInsertValue {
        .sql("ARRAY[]::\(elementType)[]")
    }
}

extension PostgresInsertValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .bind(value)
    }
}

extension PostgresInsertValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .bind(value)
    }
}

extension PostgresInsertValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .bind(value)
    }
}

extension PostgresInsertValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bind(value)
    }
}

extension PostgresInsertValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

internal func quoteLiteralSQL(_ literal: String) -> String {
    "\(PostgresQuoting.quoteLiteral(literal))"
}

/// A type name for a cast. Plain names keep SQL's own spelling, so `integer`, `double precision`,
/// `numeric(10,2)`, `text[]` and `sales.address` work (quoting them would ask for a type named
/// `"integer"` or `"text[]"`); anything else is quoted. Names of several words are only SQL's own
/// (`double precision`, `character varying`, `bit varying`, `… with time zone`): any other words
/// would be SQL, not a type name.
internal func quoteTypeNameSQL(_ typeName: String) -> String {
    let identifier = "[A-Za-z_][A-Za-z0-9_]*"
    let base = "(double precision|(national )?char(acter)? varying|national char(acter)?|bit varying|\(identifier)(\\.\(identifier))?)"
    let plain = "^\(base)(\\([0-9 ,]+\\))?( with(out)? time zone)?(\\[[0-9]*\\])*$"
    if typeName.range(of: plain, options: [.regularExpression, .caseInsensitive]) != nil { return typeName }
    return typeName.split(separator: ".", maxSplits: 1)
        .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        .joined(separator: ".")
}
