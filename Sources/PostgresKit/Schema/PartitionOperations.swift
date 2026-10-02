
/// High-level table partitioning and partition management operations.
public extension PostgresAdminClient {
    /// Create a partitioned table.
    @discardableResult
    func createPartitionedTable(
        name: String,
        schema: String? = nil,
        columns: [PostgresColumnDefinition],
        partitionBy: PartitionStrategy,
        partitionColumns: [String]
    ) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)

        let columnDefinitions = columns.map { column in
            var columnDef = "\(client.quoteIdentifier(column.name)) \(column.dataType)"
            if let defaultValue = column.defaultValue { columnDef += " DEFAULT \(defaultValue)" }
            if column.nullable == false { columnDef += " NOT NULL" }
            if column.primaryKey { columnDef += " PRIMARY KEY" }
            if column.unique { columnDef += " UNIQUE" }
            return columnDef
        }.joined(separator: ", ")

        let partitionKeyColumns = partitionColumns.map(client.quoteIdentifier).joined(separator: ", ")
        let sql = "CREATE TABLE \(qualifiedName) (\(columnDefinitions)) PARTITION BY \(partitionBy.rawValue) (\(partitionKeyColumns))"
        return try await client.executeDDL(sql)
    }

    /// Create a partition of an existing partitioned table.
    @discardableResult
    func createPartition(
        name: String,
        schema: String? = nil,
        parentTable: String,
        parentSchema: String? = nil,
        bound: String
    ) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let qualifiedParent = parentSchema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(parentTable))" } ?? client.quoteIdentifier(parentTable)
        let sql = "CREATE TABLE \(qualifiedName) PARTITION OF \(qualifiedParent) \(bound)"
        return try await client.executeDDL(sql)
    }

    /// Attach an existing table as a partition.
    @discardableResult
    func attachPartition(
        table: String,
        schema: String? = nil,
        parentTable: String,
        parentSchema: String? = nil,
        bound: String
    ) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let qualifiedParent = parentSchema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(parentTable))" } ?? client.quoteIdentifier(parentTable)
        let sql = "ALTER TABLE \(qualifiedParent) ATTACH PARTITION \(qualifiedTable) \(bound)"
        return try await client.executeDDL(sql)
    }

    /// Detach a partition from a partitioned table.
    @discardableResult
    func detachPartition(
        table: String,
        schema: String? = nil,
        parentTable: String,
        parentSchema: String? = nil,
        concurrently: Bool = false
    ) async throws -> Int {
        let qualifiedTable = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        let qualifiedParent = parentSchema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(parentTable))" } ?? client.quoteIdentifier(parentTable)
        var sql = "ALTER TABLE \(qualifiedParent) DETACH PARTITION \(qualifiedTable)"
        if concurrently { sql += " CONCURRENTLY" }
        return try await client.executeDDL(sql)
    }
}
