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
    /// Operator class parameters, such as `["siglen": "32"]` for `tsvector_ops` or `gist_trgm_ops`
    /// (PostgreSQL 13+). Written in key order.
    public let operatorClassParameters: [String: String]
    /// The column's collation for this index (`COLLATE "C"`), e.g. for `LIKE 'abc%'` on a non-C database.
    public let collation: String?
    public let isExpression: Bool

    public init(
        name: String,
        collation: String? = nil,
        operatorClass: String? = nil,
        operatorClassParameters: [String: String] = [:],
        order: PostgresIndexOrder? = nil,
        nullsOrder: PostgresIndexNullsOrder? = nil
    ) {
        self.name = name
        self.order = order
        self.nullsOrder = nullsOrder
        self.operatorClass = operatorClass
        self.operatorClassParameters = operatorClassParameters
        self.collation = collation
        self.isExpression = false
    }

    /// An expression index column, e.g. `lower(email)`.
    public init(
        expression: String,
        collation: String? = nil,
        operatorClass: String? = nil,
        operatorClassParameters: [String: String] = [:],
        order: PostgresIndexOrder? = nil,
        nullsOrder: PostgresIndexNullsOrder? = nil
    ) {
        self.name = expression
        self.order = order
        self.nullsOrder = nullsOrder
        self.operatorClass = operatorClass
        self.operatorClassParameters = operatorClassParameters
        self.collation = collation
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
