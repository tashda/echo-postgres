import Foundation

public struct PostgresActivityOptions: Sendable, Equatable {
    public var includeSqlText: Bool
    public var includeQueryPlan: Bool

    public init(includeSqlText: Bool = true, includeQueryPlan: Bool = false) {
        self.includeSqlText = includeSqlText
        self.includeQueryPlan = includeQueryPlan
    }
}

public struct PostgresActivityOverview: Sendable {
    public let connectionsCount: Int
    public let maxConnections: Int
    public let cacheHitPercent: Double
    public let transactionsPerSec: Double
    public let databaseIOMBPerSec: Double
    public let totalDeadTuples: Int64

    public init(
        connectionsCount: Int,
        maxConnections: Int,
        cacheHitPercent: Double,
        transactionsPerSec: Double,
        databaseIOMBPerSec: Double,
        totalDeadTuples: Int64
    ) {
        self.connectionsCount = connectionsCount
        self.maxConnections = maxConnections
        self.cacheHitPercent = cacheHitPercent
        self.transactionsPerSec = transactionsPerSec
        self.databaseIOMBPerSec = databaseIOMBPerSec
        self.totalDeadTuples = totalDeadTuples
    }
}

public struct PostgresActivitySnapshot: Sendable {
    public let capturedAt: Date
    public let connectedDatabase: String
    public let overview: PostgresActivityOverview?
    public let processes: [PostgresProcessInfo]
    public let waits: [PostgresWaitStat]
    public let waitsDelta: [PostgresWaitStatDelta]?
    public let databaseStats: [PostgresDatabaseStat]
    public let databaseStatsDelta: [PostgresDatabaseStatDelta]?
    public let expensiveQueries: [PostgresExpensiveQuery]
    public let pgStatStatementsAvailable: Bool
    public let locks: [PostgresLockInfo]
    public let tableStats: [PostgresTableStat]
    public let replicationInfo: [PostgresReplicationInfo]
    public let operationProgress: [PostgresOperationProgress]

    public init(
        capturedAt: Date = Date(),
        connectedDatabase: String = "postgres",
        overview: PostgresActivityOverview? = nil,
        processes: [PostgresProcessInfo],
        waits: [PostgresWaitStat],
        waitsDelta: [PostgresWaitStatDelta]? = nil,
        databaseStats: [PostgresDatabaseStat],
        databaseStatsDelta: [PostgresDatabaseStatDelta]? = nil,
        expensiveQueries: [PostgresExpensiveQuery],
        pgStatStatementsAvailable: Bool = true,
        locks: [PostgresLockInfo] = [],
        tableStats: [PostgresTableStat] = [],
        replicationInfo: [PostgresReplicationInfo] = [],
        operationProgress: [PostgresOperationProgress] = []
    ) {
        self.capturedAt = capturedAt
        self.connectedDatabase = connectedDatabase
        self.overview = overview
        self.processes = processes
        self.waits = waits
        self.waitsDelta = waitsDelta
        self.databaseStats = databaseStats
        self.databaseStatsDelta = databaseStatsDelta
        self.expensiveQueries = expensiveQueries
        self.pgStatStatementsAvailable = pgStatStatementsAvailable
        self.locks = locks
        self.tableStats = tableStats
        self.replicationInfo = replicationInfo
        self.operationProgress = operationProgress
    }
}

// MARK: - Process Info

public struct PostgresProcessInfo: Sendable, Identifiable {
    public var id: Int32 { pid }

    public let pid: Int32
    public let databaseName: String?
    public let userName: String?
    public let applicationName: String?
    public let clientAddress: String?
    public let backendStart: Date?
    public let xactStart: Date?
    public let queryStart: Date?
    public let stateChange: Date?
    public let waitEventType: String?
    public let waitEvent: String?
    public let state: String?
    public let query: String?
    public let backendType: String?
    public let isBlocked: Bool
}

// MARK: - Wait Stats

public struct PostgresWaitStat: Sendable {
    public let waitEventType: String
    public let waitEvent: String
    public let count: Int
}

public struct PostgresWaitStatDelta: Sendable, Identifiable {
    public var id: String { "\(waitEventType):\(waitEvent)" }

    public let waitEventType: String
    public let waitEvent: String
    public let countDelta: Int
}

// MARK: - Database Stats

public struct PostgresDatabaseStat: Sendable {
    public let datname: String
    public let numbackends: Int
    public let xact_commit: Int64
    public let xact_rollback: Int64
    public let blks_read: Int64
    public let blks_hit: Int64
    public let tup_returned: Int64
    public let tup_fetched: Int64
    public let tup_inserted: Int64
    public let tup_updated: Int64
    public let tup_deleted: Int64
    public let temp_files: Int64
    public let deadlocks: Int64
}

public struct PostgresDatabaseStatDelta: Sendable, Identifiable {
    public var id: String { datname }

    public let datname: String
    public let xact_commit_delta: Int64
    public let xact_rollback_delta: Int64
    public let blks_read_delta: Int64
    public let blks_hit_delta: Int64
    public let tup_inserted_delta: Int64
    public let tup_updated_delta: Int64
    public let tup_deleted_delta: Int64
    public let temp_files_delta: Int64
    public let deadlocks_delta: Int64

    public var cacheHitRatio: Double? {
        let total = blks_hit_delta + blks_read_delta
        guard total > 0 else { return nil }
        return Double(blks_hit_delta) / Double(total) * 100.0
    }
}

// MARK: - Expensive Queries

public struct PostgresExpensiveQuery: Sendable, Identifiable {
    public var id: String { "\(queryid ?? 0):\(query)" }

    public let queryid: Int64?
    public let query: String
    public let calls: Int64
    public let total_exec_time: Double
    public let min_exec_time: Double
    public let max_exec_time: Double
    public let mean_exec_time: Double
    public let rows: Int64
}

// MARK: - Lock Info

public struct PostgresLockInfo: Sendable, Identifiable {
    public var id: String { "\(pid):\(locktype):\(mode):\(relation ?? "")" }

    public let pid: Int32
    public let databaseName: String?
    public let locktype: String
    public let relation: String?
    public let mode: String
    public let granted: Bool
    public let blockingPid: Int32?
    public let query: String?
    public let state: String?
    public let waitDuration: TimeInterval?
}

// MARK: - Table Stats

public struct PostgresTableStat: Sendable, Identifiable {
    public var id: String { "\(schemaName).\(tableName)" }

    public let schemaName: String
    public let tableName: String
    public let seqScan: Int64
    public let seqTupRead: Int64
    public let idxScan: Int64
    public let idxTupFetch: Int64
    public let nLiveTup: Int64
    public let nDeadTup: Int64
    public let lastVacuum: Date?
    public let lastAutoVacuum: Date?
    public let lastAnalyze: Date?
    public let lastAutoAnalyze: Date?

    public init(schemaName: String, tableName: String, seqScan: Int64, seqTupRead: Int64, idxScan: Int64, idxTupFetch: Int64, nLiveTup: Int64, nDeadTup: Int64, lastVacuum: Date?, lastAutoVacuum: Date?, lastAnalyze: Date?, lastAutoAnalyze: Date?) {
        self.schemaName = schemaName
        self.tableName = tableName
        self.seqScan = seqScan
        self.seqTupRead = seqTupRead
        self.idxScan = idxScan
        self.idxTupFetch = idxTupFetch
        self.nLiveTup = nLiveTup
        self.nDeadTup = nDeadTup
        self.lastVacuum = lastVacuum
        self.lastAutoVacuum = lastAutoVacuum
        self.lastAnalyze = lastAnalyze
        self.lastAutoAnalyze = lastAutoAnalyze
    }
}

// MARK: - Operation Progress

public struct PostgresOperationProgress: Sendable, Identifiable {
    public var id: String { "\(pid):\(operation)" }

    public let pid: Int32
    public let operation: String
    public let phase: String
    public let databaseName: String?
    public let relation: String?
    public let progressPercent: Double?
    public let startedAt: Date?

    public init(
        pid: Int32,
        operation: String,
        phase: String,
        databaseName: String? = nil,
        relation: String? = nil,
        progressPercent: Double? = nil,
        startedAt: Date? = nil
    ) {
        self.pid = pid
        self.operation = operation
        self.phase = phase
        self.databaseName = databaseName
        self.relation = relation
        self.progressPercent = progressPercent
        self.startedAt = startedAt
    }
}

// MARK: - Replication Info

public struct PostgresReplicationInfo: Sendable, Identifiable {
    public var id: Int32 { pid }

    public let pid: Int32
    public let usename: String
    public let applicationName: String
    public let clientAddr: String?
    public let state: String
    public let sentLsn: String?
    public let writeLsn: String?
    public let flushLsn: String?
    public let replayLsn: String?
    public let writeLag: String?
    public let flushLag: String?
    public let replayLag: String?
}
