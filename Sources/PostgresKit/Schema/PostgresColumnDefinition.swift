import Foundation

/// Defines a column within a PostgreSQL table.
public struct PostgresColumnDefinition: Sendable {
    public let name: String
    public let dataType: String
    public let nullable: Bool
    public let defaultValue: String?
    public let primaryKey: Bool
    public let unique: Bool

    public init(
        name: String,
        dataType: String,
        nullable: Bool = true,
        defaultValue: String? = nil,
        primaryKey: Bool = false,
        unique: Bool = false
    ) {
        self.name = name
        self.dataType = dataType
        self.nullable = nullable
        self.defaultValue = defaultValue
        self.primaryKey = primaryKey
        self.unique = unique
    }
}

// MARK: - Common Data Types

public extension PostgresColumnDefinition {
    /// Standard INTEGER type.
    static func integer(name: String, nullable: Bool = true, defaultValue: Int? = nil) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "INTEGER", nullable: nullable, defaultValue: defaultValue.map { String($0) })
    }

    /// Standard BIGINT type.
    static func bigInt(name: String, nullable: Bool = true, defaultValue: Int? = nil) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "BIGINT", nullable: nullable, defaultValue: defaultValue.map { String($0) })
    }

    /// Auto-incrementing SERIAL type.
    static func serial(name: String, primaryKey: Bool = false) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "SERIAL", nullable: false, primaryKey: primaryKey, unique: false)
    }

    /// Auto-incrementing BIGSERIAL type.
    static func bigSerial(name: String, primaryKey: Bool = false) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "BIGSERIAL", nullable: false, primaryKey: primaryKey, unique: false)
    }

    /// DECIMAL type with precision and scale.
    static func decimal(name: String, precision: Int = 10, scale: Int = 0, nullable: Bool = true) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "DECIMAL(\(precision),\(scale))", nullable: nullable)
    }

    /// Floating point REAL type.
    static func real(name: String, nullable: Bool = true) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "REAL", nullable: nullable)
    }

    /// Double precision floating point type.
    static func double(name: String, nullable: Bool = true) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "DOUBLE PRECISION", nullable: nullable)
    }

    /// Unbounded TEXT type.
    static func text(name: String, nullable: Bool = true, defaultValue: String? = nil) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "TEXT", nullable: nullable, defaultValue: defaultValue.map(PostgresQuoting.quoteLiteral))
    }

    /// Variable-length character string with limit.
    static func varchar(name: String, length: Int = 255, nullable: Bool = true, defaultValue: String? = nil) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "VARCHAR(\(length))", nullable: nullable, defaultValue: defaultValue.map(PostgresQuoting.quoteLiteral))
    }

    /// Fixed-length character string.
    static func char(name: String, length: Int = 1, nullable: Bool = true, defaultValue: String? = nil) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "CHAR(\(length))", nullable: nullable, defaultValue: defaultValue.map(PostgresQuoting.quoteLiteral))
    }

    /// BOOLEAN type.
    static func boolean(name: String, nullable: Bool = true, defaultValue: Bool? = nil) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "BOOLEAN", nullable: nullable, defaultValue: defaultValue.map { $0 ? "TRUE" : "FALSE" })
    }

    /// TIMESTAMP type without time zone.
    static func timestamp(name: String, nullable: Bool = true, defaultValue: String? = nil) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "TIMESTAMP", nullable: nullable, defaultValue: defaultValue ?? "CURRENT_TIMESTAMP")
    }

    /// TIMESTAMP with time zone support.
    static func timestampWithTimeZone(name: String, nullable: Bool = true, defaultValue: String? = nil) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "TIMESTAMPTZ", nullable: nullable, defaultValue: defaultValue ?? "CURRENT_TIMESTAMP")
    }

    /// DATE type.
    static func date(name: String, nullable: Bool = true, defaultValue: String? = nil) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "DATE", nullable: nullable, defaultValue: defaultValue ?? "CURRENT_DATE")
    }

    /// TIME type without time zone.
    static func time(name: String, nullable: Bool = true, defaultValue: String? = nil) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "TIME", nullable: nullable, defaultValue: defaultValue ?? "CURRENT_TIME")
    }

    /// TIME with time zone support.
    static func timeWithTimeZone(name: String, nullable: Bool = true, defaultValue: String? = nil) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "TIMETZ", nullable: nullable, defaultValue: defaultValue ?? "CURRENT_TIME")
    }

    /// JSON type.
    static func json(name: String, nullable: Bool = true) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "JSON", nullable: nullable)
    }

    /// Binary JSONB type.
    static func jsonb(name: String, nullable: Bool = true) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "JSONB", nullable: nullable)
    }

    /// Binary data BYTEA type.
    static func bytea(name: String, nullable: Bool = true) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "BYTEA", nullable: nullable)
    }

    /// UUID type.
    static func uuid(name: String, nullable: Bool = true, defaultValue: String? = nil) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "UUID", nullable: nullable, defaultValue: defaultValue ?? "gen_random_uuid()")
    }

    /// Homogeneous array type.
    static func array(name: String, elementType: String, nullable: Bool = true) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "\(elementType)[]", nullable: nullable)
    }

    /// IP address INET type.
    static func inet(name: String, nullable: Bool = true) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "INET", nullable: nullable)
    }

    /// Network CIDR type.
    static func cidr(name: String, nullable: Bool = true) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "CIDR", nullable: nullable)
    }

    /// MAC address type.
    static func macaddr(name: String, nullable: Bool = true) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: "MACADDR", nullable: nullable)
    }

    /// Use a custom (e.g., enum) type.
    static func enumType(name: String, typeName: String, nullable: Bool = true, defaultValue: String? = nil) -> PostgresColumnDefinition {
        PostgresColumnDefinition(name: name, dataType: typeName, nullable: nullable, defaultValue: defaultValue.map(PostgresQuoting.quoteLiteral))
    }
}
