import Foundation

/// I/O statistics for a table from pg_statio_user_tables.
public struct PostgresTableIOStats: Sendable {
    public let schemaName: String
    public let tableName: String
    public let heapBlksRead: Int64
    public let heapBlksHit: Int64
    public let idxBlksRead: Int64
    public let idxBlksHit: Int64
    public let toastBlksRead: Int64
    public let toastBlksHit: Int64

    public init(
        schemaName: String, tableName: String,
        heapBlksRead: Int64, heapBlksHit: Int64,
        idxBlksRead: Int64, idxBlksHit: Int64,
        toastBlksRead: Int64, toastBlksHit: Int64
    ) {
        self.schemaName = schemaName
        self.tableName = tableName
        self.heapBlksRead = heapBlksRead
        self.heapBlksHit = heapBlksHit
        self.idxBlksRead = idxBlksRead
        self.idxBlksHit = idxBlksHit
        self.toastBlksRead = toastBlksRead
        self.toastBlksHit = toastBlksHit
    }
}

/// WAL statistics from pg_stat_wal (PG14+).
public struct PostgresWALStats: Sendable {
    public let walRecords: Int64
    public let walFPI: Int64
    public let walBytes: Int64
    public let walBuffersFull: Int64
    public let walWrite: Int64
    public let walSync: Int64
    public let walWriteTime: Double
    public let walSyncTime: Double
    public let statsReset: String?

    public init(
        walRecords: Int64, walFPI: Int64, walBytes: Int64,
        walBuffersFull: Int64, walWrite: Int64, walSync: Int64,
        walWriteTime: Double, walSyncTime: Double, statsReset: String?
    ) {
        self.walRecords = walRecords
        self.walFPI = walFPI
        self.walBytes = walBytes
        self.walBuffersFull = walBuffersFull
        self.walWrite = walWrite
        self.walSync = walSync
        self.walWriteTime = walWriteTime
        self.walSyncTime = walSyncTime
        self.statsReset = statsReset
    }
}

/// Background writer statistics from pg_stat_bgwriter.
public struct PostgresBGWriterStats: Sendable {
    public let checkpointsTimed: Int64
    public let checkpointsReq: Int64
    public let checkpointWriteTime: Double
    public let checkpointSyncTime: Double
    public let buffersCheckpoint: Int64
    public let buffersClean: Int64
    public let maxwrittenClean: Int64
    public let buffersBackend: Int64
    public let buffersBackendFsync: Int64
    public let buffersAlloc: Int64

    public init(
        checkpointsTimed: Int64, checkpointsReq: Int64,
        checkpointWriteTime: Double, checkpointSyncTime: Double,
        buffersCheckpoint: Int64, buffersClean: Int64,
        maxwrittenClean: Int64, buffersBackend: Int64,
        buffersBackendFsync: Int64, buffersAlloc: Int64
    ) {
        self.checkpointsTimed = checkpointsTimed
        self.checkpointsReq = checkpointsReq
        self.checkpointWriteTime = checkpointWriteTime
        self.checkpointSyncTime = checkpointSyncTime
        self.buffersCheckpoint = buffersCheckpoint
        self.buffersClean = buffersClean
        self.maxwrittenClean = maxwrittenClean
        self.buffersBackend = buffersBackend
        self.buffersBackendFsync = buffersBackendFsync
        self.buffersAlloc = buffersAlloc
    }
}

/// A prepared (two-phase) transaction from pg_prepared_xacts.
public struct PostgresPreparedTransaction: Sendable {
    public let transactionID: String
    public let gid: String
    public let prepared: String
    public let owner: String
    public let database: String

    public init(transactionID: String, gid: String, prepared: String, owner: String, database: String) {
        self.transactionID = transactionID
        self.gid = gid
        self.prepared = prepared
        self.owner = owner
        self.database = database
    }
}

/// A server setting from pg_settings.
public struct PostgresServerSetting: Sendable {
    public let name: String
    public let setting: String
    public let unit: String?
    public let category: String
    public let shortDesc: String
    public let context: String
    public let vartype: String
    public let source: String
    public let minVal: String?
    public let maxVal: String?
    public let enumVals: [String]?
    public let bootVal: String?
    public let resetVal: String?
    public let pendingRestart: Bool

    public init(
        name: String, setting: String, unit: String?,
        category: String, shortDesc: String, context: String,
        vartype: String, source: String,
        minVal: String?, maxVal: String?,
        enumVals: [String]?, bootVal: String?, resetVal: String?,
        pendingRestart: Bool
    ) {
        self.name = name
        self.setting = setting
        self.unit = unit
        self.category = category
        self.shortDesc = shortDesc
        self.context = context
        self.vartype = vartype
        self.source = source
        self.minVal = minVal
        self.maxVal = maxVal
        self.enumVals = enumVals
        self.bootVal = bootVal
        self.resetVal = resetVal
        self.pendingRestart = pendingRestart
    }
}

/// A search result from cross-object search.
public struct PostgresSearchResult: Sendable {
    public let objectType: String
    public let schemaName: String
    public let objectName: String

    public init(objectType: String, schemaName: String, objectName: String) {
        self.objectType = objectType
        self.schemaName = schemaName
        self.objectName = objectName
    }
}
