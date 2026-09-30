import Foundation

/// PostgreSQL index types.
public enum PostgresIndexType: Sendable {
    case btree
    case hash
    case gist
    case gin
    case brin
    case spgist
}

/// PostgreSQL index column definition.
public struct PostgresIndexColumn: Sendable {
    /// A column name, or an expression when `isExpression` is true.
    public let name: String
    public let order: PostgresIndexOrder?
    public let nullsOrder: PostgresIndexNullsOrder?
    /// An operator class such as `jsonb_path_ops` or `gin_trgm_ops`.
    public let operatorClass: String?
    public let isExpression: Bool

    public init(
        name: String,
        operatorClass: String? = nil,
        order: PostgresIndexOrder? = nil,
        nullsOrder: PostgresIndexNullsOrder? = nil
    ) {
        self.name = name
        self.order = order
        self.nullsOrder = nullsOrder
        self.operatorClass = operatorClass
        self.isExpression = false
    }

    /// An expression index column, e.g. `lower(email)`.
    public init(
        expression: String,
        operatorClass: String? = nil,
        order: PostgresIndexOrder? = nil,
        nullsOrder: PostgresIndexNullsOrder? = nil
    ) {
        self.name = expression
        self.order = order
        self.nullsOrder = nullsOrder
        self.operatorClass = operatorClass
        self.isExpression = true
    }
}

/// PostgreSQL index column order.
public enum PostgresIndexOrder: String, Sendable {
    case asc = "ASC"
    case desc = "DESC"
}

/// PostgreSQL index NULLS order.
public enum PostgresIndexNullsOrder: String, Sendable {
    case first = "FIRST"
    case last = "LAST"
}
