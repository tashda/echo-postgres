import Foundation

/// Information about a logical replication publication.
public struct PostgresPublicationInfo: Sendable {
    public let name: String
    public let owner: String
    public let allTables: Bool
    public let publishInsert: Bool
    public let publishUpdate: Bool
    public let publishDelete: Bool
    public let publishTruncate: Bool

    public init(
        name: String, owner: String, allTables: Bool,
        publishInsert: Bool, publishUpdate: Bool,
        publishDelete: Bool, publishTruncate: Bool
    ) {
        self.name = name
        self.owner = owner
        self.allTables = allTables
        self.publishInsert = publishInsert
        self.publishUpdate = publishUpdate
        self.publishDelete = publishDelete
        self.publishTruncate = publishTruncate
    }
}

/// A table belonging to a publication.
public struct PostgresPublicationTableInfo: Sendable {
    public let schemaName: String
    public let tableName: String

    public init(schemaName: String, tableName: String) {
        self.schemaName = schemaName
        self.tableName = tableName
    }
}

/// Information about a logical replication subscription.
public struct PostgresSubscriptionInfo: Sendable {
    public let name: String
    public let owner: String
    public let enabled: Bool
    public let connectionInfo: String
    public let publications: [String]
    public let slotName: String?

    public init(
        name: String, owner: String, enabled: Bool,
        connectionInfo: String, publications: [String], slotName: String?
    ) {
        self.name = name
        self.owner = owner
        self.enabled = enabled
        self.connectionInfo = connectionInfo
        self.publications = publications
        self.slotName = slotName
    }
}

/// Information about a replication slot.
public struct PostgresReplicationSlotInfo: Sendable {
    public let slotName: String
    public let plugin: String?
    public let slotType: String
    public let active: Bool
    public let confirmedFlushLSN: String?

    public init(
        slotName: String, plugin: String?, slotType: String,
        active: Bool, confirmedFlushLSN: String?
    ) {
        self.slotName = slotName
        self.plugin = plugin
        self.slotType = slotType
        self.active = active
        self.confirmedFlushLSN = confirmedFlushLSN
    }
}
