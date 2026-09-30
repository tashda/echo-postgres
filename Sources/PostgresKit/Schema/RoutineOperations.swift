import PostgresWire
import PostgresNIO

/// High-level Function and Procedure Data Definition Language (DDL) operations.
public extension PostgresRoutineClient {
    /// Create a new SQL function.
    @discardableResult
    func createFunction(
        name: String,
        schema: String? = nil,
        parameters: [PostgresFunctionParameter],
        returnType: String,
        body: String,
        language: PostgresFunctionLanguage = .sql,
        orReplace: Bool = false,
        security: PostgresFunctionSecurity = .definer,
        immutable: Bool = false,
        stable: Bool = false,
        volatile: Bool = false,
        returnsNullOnNullInput: Bool = false,
        strict: Bool = false,
        cost: Int? = nil,
        rows: Int? = nil
    ) async throws -> Int {
        var parts: [String] = ["CREATE"]
        if orReplace { parts.append("OR REPLACE") }
        parts.append("FUNCTION")
        parts.append(client.quoteQualified(name, schema: schema))

        let paramList = parameters.map { param in
            var paramDef = "\(client.quoteIdentifier(param.name)) \(param.dataType)"
            if let defaultValue = param.defaultValue { paramDef += " DEFAULT \(defaultValue)" }
            if param.mode == .`in` { paramDef = "IN " + paramDef }
            else if param.mode == .`out` { paramDef = "OUT " + paramDef }
            else if param.mode == .`inout` { paramDef = "INOUT " + paramDef }
            return paramDef
        }.joined(separator: ", ")

        parts.append("(\(paramList))")
        parts.append("RETURNS \(returnType)")
        parts.append("LANGUAGE \(language.rawValue)")

        if immutable { parts.append("IMMUTABLE") }
        else if stable { parts.append("STABLE") }
        else if volatile { parts.append("VOLATILE") }

        if security == .definer { parts.append("SECURITY DEFINER") }
        else if security == .invoker { parts.append("SECURITY INVOKER") }

        if returnsNullOnNullInput { parts.append("RETURNS NULL ON NULL INPUT") }
        if strict { parts.append("STRICT") }

        if let cost { parts.append("COST \(cost)") }
        if let rows { parts.append("ROWS \(rows)") }

        parts.append("AS \(client.quoteLiteral(body))")
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Drop an existing function.
    @discardableResult
    func dropFunction(name: String, parameters: [String] = [], ifExists: Bool = false, cascade: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP FUNCTION"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        if !parameters.isEmpty { parts.append("(\(parameters.joined(separator: ", ")))") }
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Execute a function and decode the first returned value.
    func executeFunction<T: PostgresDecodable & Sendable>(
        _ name: String,
        parameters: [Any] = [],
        decodeTo: T.Type
    ) async throws -> T {
        let paramPlaceholders = parameters.enumerated().map { index, _ in "$\(index + 1)" }.joined(separator: ", ")
        let binds = try parameters.map { try client.toPGData(value: $0) }
        let sql = "SELECT * FROM \(client.quoteIdentifier(name))(\(paramPlaceholders))"

        return try await client.withConnection { conn in
            let rows = try await conn.query(sql, binds: binds)
            for try await value in rows.decode(decodeTo) { return value }
            throw PostgresKit.PostgresError.protocolError("Function \(name) returned no value")
        }
    }
}
