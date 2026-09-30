import PostgresWire

/// High-level Sequence Data Definition Language (DDL) operations.
public extension PostgresSequenceClient {
    /// Create a new sequence.
    @discardableResult
    func createSequence(
        name: String,
        schema: String? = nil,
        temporary: Bool = false,
        ifNotExists: Bool = false,
        startWith: Int? = nil,
        incrementBy: Int? = nil,
        minValue: Int? = nil,
        maxValue: Int? = nil,
        cache: Int? = nil,
        cycle: Bool = false
    ) async throws -> Int {
        var parts: [String] = ["CREATE"]
        if temporary { parts.append("TEMPORARY") }
        parts.append("SEQUENCE")
        if ifNotExists { parts.append("IF NOT EXISTS") }
        parts.append(client.quoteQualified(name, schema: schema))

        if let startWith { parts.append("START WITH \(startWith)") }
        if let incrementBy { parts.append("INCREMENT BY \(incrementBy)") }
        if let minValue { parts.append("MINVALUE \(minValue)") }
        if let maxValue { parts.append("MAXVALUE \(maxValue)") }
        if let cache { parts.append("CACHE \(cache)") }
        if cycle { parts.append("CYCLE") }

        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Drop an existing sequence.
    @discardableResult
    func dropSequence(name: String, ifExists: Bool = false, cascade: Bool = false) async throws -> Int {
        var parts: [String] = ["DROP SEQUENCE"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(client.quoteIdentifier(name))
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Advance the sequence and return its new value.
    func nextval(_ sequenceName: String) async throws -> Int {
        let sql = "SELECT nextval(\(client.quoteLiteral(sequenceName))::text)::bigint as value"
        let rows = try await client.simpleQuery(sql)
        for try await value in rows.decode(Int.self) { return value }
        throw PostgresKit.PostgresError.protocolError("Sequence \(sequenceName) returned no value")
    }

    /// Return the most recently obtained value for the sequence in the current session.
    func currval(_ sequenceName: String) async throws -> Int {
        let sql = "SELECT currval(\(client.quoteLiteral(sequenceName))::text)::bigint as value"
        let rows = try await client.simpleQuery(sql)
        for try await value in rows.decode(Int.self) { return value }
        throw PostgresKit.PostgresError.protocolError("Sequence \(sequenceName) returned no value")
    }

    /// Reset the sequence's counter value.
    @discardableResult
    func setval(_ sequenceName: String, value: Int, isCalled: Bool = true) async throws -> Int {
        let sql = "SELECT setval(\(client.quoteLiteral(sequenceName))::text, \(value), \(isCalled))"
        return try await client.executeDDL(sql)
    }

    // MARK: - ALTER SEQUENCE

    /// Alter a sequence's properties. Only non-nil parameters are changed.
    @discardableResult
    func alterSequence(
        name: String,
        incrementBy: Int? = nil,
        minValue: Int? = nil,
        noMinValue: Bool = false,
        maxValue: Int? = nil,
        noMaxValue: Bool = false,
        startWith: Int? = nil,
        restartWith: Int? = nil,
        cache: Int? = nil,
        cycle: Bool? = nil,
        ownedBy: String? = nil,
        schema: String? = nil
    ) async throws -> Int {
        let qualified: String
        if let schema {
            qualified = "\(client.quoteIdentifier(schema)).\(client.quoteIdentifier(name))"
        } else {
            qualified = client.quoteIdentifier(name)
        }

        var parts: [String] = ["ALTER SEQUENCE", qualified]

        if let incrementBy { parts.append("INCREMENT BY \(incrementBy)") }
        if noMinValue {
            parts.append("NO MINVALUE")
        } else if let minValue {
            parts.append("MINVALUE \(minValue)")
        }
        if noMaxValue {
            parts.append("NO MAXVALUE")
        } else if let maxValue {
            parts.append("MAXVALUE \(maxValue)")
        }
        if let startWith { parts.append("START WITH \(startWith)") }
        if let restartWith { parts.append("RESTART WITH \(restartWith)") }
        if let cache { parts.append("CACHE \(cache)") }
        if let cycle { parts.append(cycle ? "CYCLE" : "NO CYCLE") }
        if let ownedBy { parts.append("OWNED BY \(ownedBy)") }

        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Rename a sequence.
    @discardableResult
    func alterSequenceRename(name: String, newName: String, schema: String? = nil) async throws -> Int {
        let qualified: String
        if let schema {
            qualified = "\(client.quoteIdentifier(schema)).\(client.quoteIdentifier(name))"
        } else {
            qualified = client.quoteIdentifier(name)
        }
        return try await client.executeDDL(
            "ALTER SEQUENCE \(qualified) RENAME TO \(client.quoteIdentifier(newName))"
        )
    }

    /// Move a sequence to a different schema.
    @discardableResult
    func alterSequenceSetSchema(name: String, newSchema: String, schema: String? = nil) async throws -> Int {
        let qualified: String
        if let schema {
            qualified = "\(client.quoteIdentifier(schema)).\(client.quoteIdentifier(name))"
        } else {
            qualified = client.quoteIdentifier(name)
        }
        return try await client.executeDDL(
            "ALTER SEQUENCE \(qualified) SET SCHEMA \(client.quoteIdentifier(newSchema))"
        )
    }

    /// Change the owner of a sequence.
    @discardableResult
    func alterSequenceOwner(name: String, newOwner: String, schema: String? = nil) async throws -> Int {
        let qualified: String
        if let schema {
            qualified = "\(client.quoteIdentifier(schema)).\(client.quoteIdentifier(name))"
        } else {
            qualified = client.quoteIdentifier(name)
        }
        return try await client.executeDDL(
            "ALTER SEQUENCE \(qualified) OWNER TO \(client.quoteIdentifier(newOwner))"
        )
    }
}
