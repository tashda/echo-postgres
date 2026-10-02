
public extension PostgresConnection {
    @discardableResult
    func beginTransaction() async throws -> Int {
        try await executeDDL("BEGIN")
    }

    @discardableResult
    func commit() async throws -> Int {
        try await executeDDL("COMMIT")
    }

    @discardableResult
    func rollback() async throws -> Int {
        try await executeDDL("ROLLBACK")
    }

    @discardableResult
    func createTable(
        name: String,
        columns: [PostgresColumnDefinition],
        temporary: Bool = false,
        ifNotExists: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["CREATE"]
        if temporary { parts.append("TEMPORARY") }
        parts.append("TABLE")
        if ifNotExists { parts.append("IF NOT EXISTS") }
        parts.append(quoteIdentifier(name))

        let columnDefinitions = columns.map { column in
            var columnDef = "\(quoteIdentifier(column.name)) \(column.dataType)"
            if let defaultValue = column.defaultValue { columnDef += " DEFAULT \(defaultValue)" }
            if column.nullable == false { columnDef += " NOT NULL" }
            if column.primaryKey { columnDef += " PRIMARY KEY" }
            if column.unique { columnDef += " UNIQUE" }
            return columnDef
        }.joined(separator: ", ")

        parts.append("(\(columnDefinitions))")
        return try await executeDDL(parts.joined(separator: " "))
    }
}

internal extension PostgresConnection {
    func quoteIdentifier(_ identifier: String) -> String {
        PostgresQuoting.quoteQualifiedIdentifier(identifier)
    }

    func bind(_ value: Any) throws -> PostgresBind {
        guard let encodable = value as? any PostgresEncodable else { throw PostgresError.encodingError(type: type(of: value)) }
        return try encodable.postgresBind()
    }

    /// Runs a statement and returns the number of rows it returned.
    @discardableResult
    func executeDDL(_ sql: String) async throws -> Int {
        try await queryResult(sql).rows.count
    }
}
