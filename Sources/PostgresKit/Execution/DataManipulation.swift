import Foundation

/// High-level Data Manipulation Language (DML) operations.
public extension PostgresBulkClient {
    /// Insert rows into a table. Returns the number of rows inserted.
    @discardableResult
    func insert(
        into table: String,
        schema: String? = nil,
        columns: [String] = [],
        values: [[Any]]
    ) async throws -> Int {
        let converted = try values.map { row in
            try row.map(PostgresInsertValue.fromAny)
        }
        return try await insert(into: table, schema: schema, columns: columns, values: converted)
    }

    /// Insert rows using structured values that can mix binds and SQL expressions.
    /// Returns the number of rows inserted.
    @discardableResult
    func insert(
        into table: String,
        schema: String? = nil,
        columns: [String] = [],
        values: [[PostgresInsertValue]]
    ) async throws -> Int {
        try await client.withConnection { conn in
            try await conn.insert(into: table, schema: schema, columns: columns, values: values)
        }
    }

    /// Update existing rows in a table.
    @discardableResult
    func update(
        table: String,
        set: [String: Any],
        whereClause: String? = nil
    ) async throws -> Int {
        let setClause = set.map { (column, value) in
            let quotedColumn = client.quoteIdentifier(column)
            if let stringValue = value as? String {
                return "\(quotedColumn) = \(PostgresQuoting.quoteLiteral(stringValue))"
            } else {
                return "\(quotedColumn) = \(value)"
            }
        }.joined(separator: ", ")

        var sql = "UPDATE \(client.quoteIdentifier(table)) SET \(setClause)"

        if let whereClause {
            sql += " WHERE \(whereClause)"
        }

        return try await client.executeDDL(sql)
    }

    /// Delete rows from a table.
    @discardableResult
    func delete(
        from table: String,
        whereClause: String? = nil
    ) async throws -> Int {
        var sql = "DELETE FROM \(client.quoteIdentifier(table))"
        if let whereClause {
            sql += " WHERE \(whereClause)"
        }
        return try await client.executeDDL(sql)
    }

    /// Efficiently remove all rows from a table.
    @discardableResult
    func truncate(
        table: String,
        cascade: Bool = false,
        restartIdentity: Bool = false,
        schema: String? = nil
    ) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(table))" } ?? client.quoteIdentifier(table)
        var parts: [String] = ["TRUNCATE TABLE"]
        parts.append(qualifiedName)
        if cascade { parts.append("CASCADE") }
        if restartIdentity { parts.append("RESTART IDENTITY") } else { parts.append("CONTINUE IDENTITY") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }
}


public extension PostgresConnection {
    /// Insert rows using structured values that can mix binds and SQL expressions.
    /// Returns the number of rows inserted.
    @discardableResult
    func insert(
        into table: String,
        schema: String? = nil,
        columns: [String] = [],
        values: [[PostgresInsertValue]]
    ) async throws -> Int {
        if values.isEmpty { return 0 }

        let columnList = columns.isEmpty ? "" : "(\(columns.map(quoteIdentifier).joined(separator: ", ")))"

        var allBinds: [PostgresBind] = []
        var bindIndex = 1
        let valuePlaceholders = try values.map { row in
            let fragments = try row.map { value in
                switch value {
                case .bind(let encodable):
                    defer { bindIndex += 1 }
                    allBinds.append(try bind(encodable))
                    return "$\(bindIndex)"
                case .sql(let sql):
                    return sql
                }
            }
            return "(\(fragments.joined(separator: ", ")))"
        }.joined(separator: ", ")

        let target = schema.map { "\(quoteIdentifier($0)).\(quoteIdentifier(table))" } ?? quoteIdentifier(table)
        // A plain INSERT returns no rows; RETURNING one value per row gives the inserted count.
        let sql = "INSERT INTO \(target)\(columnList) VALUES \(valuePlaceholders) RETURNING 1"
        let rows = try await query(sql, binds: allBinds)
        var count = 0
        for try await _ in rows.decode(Int32.self) {
            count += 1
        }
        return count
    }
}

private extension PostgresInsertValue {
    static func fromAny(_ value: Any) throws -> PostgresInsertValue {
        if let value = value as? PostgresInsertValue {
            return value
        }
        if let encodable = value as? any PostgresEncodable {
            return .bind(encodable)
        }
        if value is NSNull {
            return .null
        }
        throw PostgresError.encodingError(type: type(of: value))
    }
}
