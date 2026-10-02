import Foundation

/// Information about a foreign data wrapper.
public struct PostgresFDWInfo: Sendable {
    public let name: String
    public let handler: String?
    public let validator: String?
    public let owner: String
    public let options: [String]?

    public init(name: String, handler: String?, validator: String?, owner: String, options: [String]?) {
        self.name = name
        self.handler = handler
        self.validator = validator
        self.owner = owner
        self.options = options
    }
}

/// Information about a foreign server.
public struct PostgresForeignServerInfo: Sendable {
    public let name: String
    public let type: String?
    public let version: String?
    public let fdwName: String
    public let owner: String
    public let options: [String]?

    public init(name: String, type: String?, version: String?, fdwName: String, owner: String, options: [String]?) {
        self.name = name
        self.type = type
        self.version = version
        self.fdwName = fdwName
        self.owner = owner
        self.options = options
    }
}

/// Information about a user mapping.
public struct PostgresUserMappingInfo: Sendable {
    public let serverName: String
    public let userName: String
    public let options: [String]?

    public init(serverName: String, userName: String, options: [String]?) {
        self.serverName = serverName
        self.userName = userName
        self.options = options
    }
}

/// Information about a foreign table.
public struct PostgresForeignTableInfo: Sendable {
    public let name: String
    public let schema: String
    public let serverName: String
    public let columns: [String]

    public init(name: String, schema: String, serverName: String, columns: [String]) {
        self.name = name
        self.schema = schema
        self.serverName = serverName
        self.columns = columns
    }
}

/// Information about an event trigger.
public struct PostgresEventTriggerInfo: Sendable {
    public let name: String
    public let event: String
    public let owner: String
    public let function: String
    public let enabled: String
    public let tags: [String]?

    public init(name: String, event: String, owner: String, function: String, enabled: String, tags: [String]?) {
        self.name = name
        self.event = event
        self.owner = owner
        self.function = function
        self.enabled = enabled
        self.tags = tags
    }
}

/// Information about a domain type.
public struct PostgresDomainInfo: Sendable {
    public let name: String
    public let schema: String
    public let dataType: String
    public let defaultValue: String?
    public let isNotNull: Bool
    public let constraints: [PostgresDomainConstraint]

    public init(
        name: String, schema: String, dataType: String,
        defaultValue: String?, isNotNull: Bool,
        constraints: [PostgresDomainConstraint]
    ) {
        self.name = name
        self.schema = schema
        self.dataType = dataType
        self.defaultValue = defaultValue
        self.isNotNull = isNotNull
        self.constraints = constraints
    }
}

/// A constraint on a domain type.
public struct PostgresDomainConstraint: Sendable {
    public let name: String
    public let expression: String

    public init(name: String, expression: String) {
        self.name = name
        self.expression = expression
    }
}

/// Information about a composite type.
public struct PostgresCompositeTypeInfo: Sendable {
    public let name: String
    public let schema: String
    public let attributes: [PostgresCompositeAttribute]

    public init(name: String, schema: String, attributes: [PostgresCompositeAttribute]) {
        self.name = name
        self.schema = schema
        self.attributes = attributes
    }
}

/// An attribute of a composite type.
public struct PostgresCompositeAttribute: Sendable {
    public let name: String
    public let dataType: String

    public init(name: String, dataType: String) {
        self.name = name
        self.dataType = dataType
    }
}

/// Information about a range type.
public struct PostgresRangeTypeInfo: Sendable {
    public let name: String
    public let schema: String
    public let subtype: String
    public let collation: String?
    public let subtypeOpClass: String?

    public init(name: String, schema: String, subtype: String, collation: String?, subtypeOpClass: String?) {
        self.name = name
        self.schema = schema
        self.subtype = subtype
        self.collation = collation
        self.subtypeOpClass = subtypeOpClass
    }
}

/// Information about a collation.
public struct PostgresCollationInfo: Sendable {
    public let name: String
    public let schema: String
    public let provider: String?
    public let locale: String?
    public let lcCollate: String?
    public let lcCtype: String?

    public init(name: String, schema: String, provider: String?, locale: String?, lcCollate: String?, lcCtype: String?) {
        self.name = name
        self.schema = schema
        self.provider = provider
        self.locale = locale
        self.lcCollate = lcCollate
        self.lcCtype = lcCtype
    }
}

/// Information about a text search configuration.
public struct PostgresFTSConfigInfo: Sendable {
    public let name: String
    public let schema: String
    public let parser: String

    public init(name: String, schema: String, parser: String) {
        self.name = name
        self.schema = schema
        self.parser = parser
    }
}

/// Information about a text search dictionary.
public struct PostgresFTSDictionaryInfo: Sendable {
    public let name: String
    public let schema: String
    public let template: String

    public init(name: String, schema: String, template: String) {
        self.name = name
        self.schema = schema
        self.template = template
    }
}

/// Information about a rule.
public struct PostgresRuleInfo: Sendable {
    public let name: String
    public let table: String
    public let schema: String
    public let event: String
    public let doInstead: Bool
    public let definition: String

    public init(name: String, table: String, schema: String, event: String, doInstead: Bool, definition: String) {
        self.name = name
        self.table = table
        self.schema = schema
        self.event = event
        self.doInstead = doInstead
        self.definition = definition
    }
}

/// Information about a tablespace.
public struct PostgresTablespaceInfo: Sendable {
    public let name: String
    public let owner: String
    public let location: String
    public let options: [String]?

    public init(name: String, owner: String, location: String, options: [String]?) {
        self.name = name
        self.owner = owner
        self.location = location
        self.options = options
    }
}
