/// Column information for result sets
public struct ColumnInfo: Sendable, Codable {
    public let name: String
    public let dataType: String
    public let isPrimaryKey: Bool
    public let isNullable: Bool
    public let maxLength: Int?

    public init(
        name: String,
        dataType: String,
        isPrimaryKey: Bool = false,
        isNullable: Bool = true,
        maxLength: Int? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.isPrimaryKey = isPrimaryKey
        self.isNullable = isNullable
        self.maxLength = maxLength
    }
}
