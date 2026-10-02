import Foundation

/// Reading cells by column name (`row[data: "pid"].int32`), as the activity monitor and catalog
/// code do.
extension PostgresRow {
    /// The row itself (cells are already reachable by name).
    public func makeRandomAccess() -> PostgresRow { self }

    /// The cell of the first column with this name; a NULL value when there is no such column.
    public subscript(data name: String) -> PostgresCellValue {
        PostgresCellValue(text: self[column: name]?.string)
    }
}

/// A cell's text with typed readers; each is nil for NULL or text of another type.
public struct PostgresCellValue: Sendable {
    public let text: String?

    public var string: String? { text }
    public var int: Int? { text.flatMap { Int($0) } }
    public var int32: Int32? { text.flatMap { Int32($0) } }
    public var int64: Int64? { text.flatMap { Int64($0) } }
    public var double: Double? { text.flatMap { try? Double.decode(text: $0) } }
    public var bool: Bool? { text.flatMap { try? Bool.decode(text: $0) } }
    public var date: Date? { text.flatMap { PostgresDateText.parse($0) } }
    public var uuid: UUID? { text.flatMap { UUID(uuidString: $0) } }
}
