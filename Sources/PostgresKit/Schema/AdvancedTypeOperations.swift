
/// Domain, composite, and range type DDL operations.
public extension PostgresTypeClient {

    // MARK: - Domain Types

    /// Create a domain type.
    @discardableResult
    func createDomain(
        name: String,
        dataType: String,
        defaultValue: String? = nil,
        notNull: Bool = false,
        checkExpression: String? = nil,
        constraintName: String? = nil,
        schema: String? = nil
    ) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        var parts: [String] = ["CREATE DOMAIN \(qualifiedName) AS \(dataType)"]
        if let defaultValue { parts.append("DEFAULT \(defaultValue)") }
        if notNull { parts.append("NOT NULL") }
        if let checkExpression {
            if let constraintName {
                parts.append("CONSTRAINT \(client.quoteIdentifier(constraintName)) CHECK (\(checkExpression))")
            } else {
                parts.append("CHECK (\(checkExpression))")
            }
        }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    /// Set a domain's default value.
    @discardableResult
    func alterDomainSetDefault(name: String, defaultValue: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER DOMAIN \(qualifiedName) SET DEFAULT \(defaultValue)"
        return try await client.executeDDL(sql)
    }

    /// Drop a domain's default value.
    @discardableResult
    func alterDomainDropDefault(name: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER DOMAIN \(qualifiedName) DROP DEFAULT"
        return try await client.executeDDL(sql)
    }

    /// Set NOT NULL on a domain.
    @discardableResult
    func alterDomainSetNotNull(name: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER DOMAIN \(qualifiedName) SET NOT NULL"
        return try await client.executeDDL(sql)
    }

    /// Drop NOT NULL from a domain.
    @discardableResult
    func alterDomainDropNotNull(name: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER DOMAIN \(qualifiedName) DROP NOT NULL"
        return try await client.executeDDL(sql)
    }

    /// Add a check constraint to a domain.
    @discardableResult
    func alterDomainAddConstraint(name: String, constraintName: String, checkExpression: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER DOMAIN \(qualifiedName) ADD CONSTRAINT \(client.quoteIdentifier(constraintName)) CHECK (\(checkExpression))"
        return try await client.executeDDL(sql)
    }

    /// Drop a constraint from a domain.
    @discardableResult
    func alterDomainDropConstraint(name: String, constraintName: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER DOMAIN \(qualifiedName) DROP CONSTRAINT \(client.quoteIdentifier(constraintName))"
        return try await client.executeDDL(sql)
    }

    /// Rename a domain.
    @discardableResult
    func alterDomainRename(name: String, newName: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER DOMAIN \(qualifiedName) RENAME TO \(client.quoteIdentifier(newName))"
        return try await client.executeDDL(sql)
    }

    /// Change a domain's owner.
    @discardableResult
    func alterDomainOwner(name: String, newOwner: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER DOMAIN \(qualifiedName) OWNER TO \(client.quoteIdentifier(newOwner))"
        return try await client.executeDDL(sql)
    }

    /// Move a domain to a different schema.
    @discardableResult
    func alterDomainSetSchema(name: String, newSchema: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER DOMAIN \(qualifiedName) SET SCHEMA \(client.quoteIdentifier(newSchema))"
        return try await client.executeDDL(sql)
    }

    /// Drop a domain type.
    @discardableResult
    func dropDomain(name: String, ifExists: Bool = false, cascade: Bool = false, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        var parts: [String] = ["DROP DOMAIN"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(qualifiedName)
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    // MARK: - Composite Types

    /// Create a composite type.
    @discardableResult
    func createCompositeType(
        name: String,
        attributes: [(name: String, dataType: String)],
        schema: String? = nil
    ) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let attrList = attributes.map { "\(client.quoteIdentifier($0.name)) \($0.dataType)" }.joined(separator: ", ")
        let sql = "CREATE TYPE \(qualifiedName) AS (\(attrList))"
        return try await client.executeDDL(sql)
    }

    /// Add an attribute to a composite type.
    @discardableResult
    func alterCompositeTypeAddAttribute(name: String, attributeName: String, dataType: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER TYPE \(qualifiedName) ADD ATTRIBUTE \(client.quoteIdentifier(attributeName)) \(dataType)"
        return try await client.executeDDL(sql)
    }

    /// Drop an attribute from a composite type.
    @discardableResult
    func alterCompositeTypeDropAttribute(name: String, attributeName: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER TYPE \(qualifiedName) DROP ATTRIBUTE \(client.quoteIdentifier(attributeName))"
        return try await client.executeDDL(sql)
    }

    /// Rename a type (composite or range).
    @discardableResult
    func alterTypeRename(name: String, newName: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER TYPE \(qualifiedName) RENAME TO \(client.quoteIdentifier(newName))"
        return try await client.executeDDL(sql)
    }

    /// Change a type's owner (composite or range).
    @discardableResult
    func alterTypeOwner(name: String, newOwner: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER TYPE \(qualifiedName) OWNER TO \(client.quoteIdentifier(newOwner))"
        return try await client.executeDDL(sql)
    }

    /// Move a type to a different schema (composite or range).
    @discardableResult
    func alterTypeSetSchema(name: String, newSchema: String, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        let sql = "ALTER TYPE \(qualifiedName) SET SCHEMA \(client.quoteIdentifier(newSchema))"
        return try await client.executeDDL(sql)
    }

    /// Drop a composite type.
    @discardableResult
    func dropCompositeType(name: String, ifExists: Bool = false, cascade: Bool = false, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        var parts: [String] = ["DROP TYPE"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(qualifiedName)
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }

    // MARK: - Range Types

    /// Create a range type.
    @discardableResult
    func createRangeType(
        name: String,
        subtype: String,
        subtypeOpClass: String? = nil,
        collation: String? = nil,
        canonicalFunction: String? = nil,
        subtypeDiffFunction: String? = nil,
        schema: String? = nil
    ) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        var clauses: [String] = ["subtype = \(subtype)"]
        if let subtypeOpClass { clauses.append("subtype_opclass = \(subtypeOpClass)") }
        if let collation { clauses.append("collation = \(collation)") }
        if let canonicalFunction { clauses.append("canonical = \(canonicalFunction)") }
        if let subtypeDiffFunction { clauses.append("subtype_diff = \(subtypeDiffFunction)") }
        let sql = "CREATE TYPE \(qualifiedName) AS RANGE (\(clauses.joined(separator: ", ")))"
        return try await client.executeDDL(sql)
    }

    /// Drop a range type.
    @discardableResult
    func dropRangeType(name: String, ifExists: Bool = false, cascade: Bool = false, schema: String? = nil) async throws -> Int {
        let qualifiedName = schema.map { "\(client.quoteIdentifier($0)).\(client.quoteIdentifier(name))" } ?? client.quoteIdentifier(name)
        var parts: [String] = ["DROP TYPE"]
        if ifExists { parts.append("IF EXISTS") }
        parts.append(qualifiedName)
        if cascade { parts.append("CASCADE") }
        return try await client.executeDDL(parts.joined(separator: " "))
    }
}
