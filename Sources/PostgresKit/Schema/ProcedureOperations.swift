import PostgresWire

/// Procedures (PostgreSQL 11+): `CREATE PROCEDURE`, run with `CALL`.
public extension PostgresRoutineClient {
    @discardableResult
    func createProcedure(
        name: String,
        schema: String? = nil,
        parameters: [PostgresFunctionParameter] = [],
        body: String,
        language: PostgresFunctionLanguage = .plpgsql,
        orReplace: Bool = false,
        security: PostgresFunctionSecurity = .invoker
    ) async throws -> Int {
        try await client.executeDDL(Self.procedureSQL(
            name: client.quoteQualified(name, schema: schema),
            parameters: parameters.map { client.parameterDefinition($0) },
            body: client.quoteLiteral(body),
            language: language,
            orReplace: orReplace,
            security: security
        ))
    }

    @discardableResult
    func dropProcedure(name: String, schema: String? = nil, argumentTypes: [String]? = nil, ifExists: Bool = false) async throws -> Int {
        var sql = "DROP PROCEDURE \(ifExists ? "IF EXISTS " : "")\(client.quoteQualified(name, schema: schema))"
        if let argumentTypes { sql += "(\(argumentTypes.joined(separator: ", ")))" }
        return try await client.executeDDL(sql)
    }

    internal static func procedureSQL(
        name: String,
        parameters: [String],
        body: String,
        language: PostgresFunctionLanguage,
        orReplace: Bool,
        security: PostgresFunctionSecurity
    ) -> String {
        [
            "CREATE\(orReplace ? " OR REPLACE" : "") PROCEDURE \(name)(\(parameters.joined(separator: ", ")))",
            "LANGUAGE \(language.rawValue)",
            security == .definer ? "SECURITY DEFINER" : "SECURITY INVOKER",
            "AS \(body)",
        ].joined(separator: " ")
    }
}

extension PostgresClient {
    /// `IN "name" type DEFAULT value`, as used in function and procedure signatures.
    internal func parameterDefinition(_ parameter: PostgresFunctionParameter) -> String {
        var definition = "\(quoteIdentifier(parameter.name)) \(parameter.dataType)"
        if let defaultValue = parameter.defaultValue { definition += " DEFAULT \(defaultValue)" }
        switch parameter.mode {
        case .`in`: return "IN " + definition
        case .`out`: return "OUT " + definition
        case .`inout`: return "INOUT " + definition
        }
    }
}
