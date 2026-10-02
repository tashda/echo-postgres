import Foundation

/// Comprehensive role information.
public struct PostgresRoleInfo: Sendable {
    public let oid: String
    public let name: String
    public let isSuperuser: Bool
    public let canCreateRole: Bool
    public let canCreateDB: Bool
    public let canLogin: Bool
    public let isReplication: Bool
    public let inherit: Bool
    public let bypassRLS: Bool
    public let connectionLimit: Int
    public let validUntil: String?

    public init(
        oid: String = "",
        name: String,
        isSuperuser: Bool,
        canCreateRole: Bool,
        canCreateDB: Bool,
        canLogin: Bool,
        isReplication: Bool,
        inherit: Bool,
        bypassRLS: Bool = false,
        connectionLimit: Int,
        validUntil: String?
    ) {
        self.oid = oid
        self.name = name
        self.isSuperuser = isSuperuser
        self.canCreateRole = canCreateRole
        self.canCreateDB = canCreateDB
        self.canLogin = canLogin
        self.isReplication = isReplication
        self.inherit = inherit
        self.bypassRLS = bypassRLS
        self.connectionLimit = connectionLimit
        self.validUntil = validUntil
    }
}

/// A security label applied to a role.
public struct PostgresSecurityLabel: Sendable {
    public let provider: String
    public let label: String

    public init(provider: String, label: String) {
        self.provider = provider
        self.label = label
    }
}

/// Detailed information about a schema.
public struct PostgresSchemaInfo: Sendable {
    public let oid: Int
    public let name: String
    public let owner: String
    public let description: String?
    public let acl: String?

    public init(oid: Int = 0, name: String, owner: String, description: String? = nil, acl: String? = nil) {
        self.oid = oid
        self.name = name
        self.owner = owner
        self.description = description
        self.acl = acl
    }
}

/// RLS policy information.
public struct PostgresPolicyInfo: Sendable {
    public let name: String
    public let tableName: String
    public let schemaName: String
    /// The command the policy applies to: ALL, SELECT, INSERT, UPDATE, or DELETE.
    public let command: String
    /// PERMISSIVE or RESTRICTIVE.
    public let type: String
    /// Role names the policy applies to, or empty for PUBLIC.
    public let roles: [String]
    public let usingExpression: String?
    public let withCheckExpression: String?

    public init(
        name: String, tableName: String, schemaName: String,
        command: String, type: String, roles: [String],
        usingExpression: String?, withCheckExpression: String?
    ) {
        self.name = name
        self.tableName = tableName
        self.schemaName = schemaName
        self.command = command
        self.type = type
        self.roles = roles
        self.usingExpression = usingExpression
        self.withCheckExpression = withCheckExpression
    }
}

/// Describes role membership relationships.
public struct PostgresRoleMembership: Sendable {
    public let roleName: String
    public let memberName: String
    public let adminOption: Bool
    public let inheritOption: Bool
    public let setOption: Bool

    public init(
        roleName: String,
        memberName: String,
        adminOption: Bool,
        inheritOption: Bool = true,
        setOption: Bool = true
    ) {
        self.roleName = roleName
        self.memberName = memberName
        self.adminOption = adminOption
        self.inheritOption = inheritOption
        self.setOption = setOption
    }
}
