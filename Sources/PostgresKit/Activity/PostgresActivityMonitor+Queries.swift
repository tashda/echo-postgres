import Foundation
import Logging

// MARK: - Lock, table, replication and progress queries

extension PostgresActivityMonitor {
    func fetchLocks() async throws -> [PostgresLockInfo] {
        // Filter out:
        // - Our own backend PID (the monitor's queries)
        // - AccessShareLock on system catalog objects (pg_*) — these are routine read locks
        //   taken by every SELECT and are not meaningful contention
        // Focus on: waiting locks, exclusive locks, locks on user relations
        let sql = """
        SELECT l.pid, a.datname, l.locktype,
               COALESCE(c.relname, l.locktype) AS relation,
               l.mode, l.granted,
               bl.pid AS blocking_pid,
               a.query, a.state,
               CASE WHEN NOT l.granted AND a.state_change IS NOT NULL
                    THEN EXTRACT(EPOCH FROM (now() - a.state_change))
                    ELSE NULL
               END AS wait_seconds
        FROM pg_locks l
        JOIN pg_stat_activity a ON l.pid = a.pid
        LEFT JOIN pg_class c ON l.relation = c.oid
        LEFT JOIN pg_locks bl ON bl.locktype = l.locktype
            AND bl.relation = l.relation
            AND bl.page = l.page
            AND bl.tuple = l.tuple
            AND bl.granted = true
            AND bl.pid <> l.pid
            AND NOT l.granted
        WHERE a.pid <> pg_backend_pid()
          AND NOT (l.mode = 'AccessShareLock' AND l.granted
                   AND c.relname IS NOT NULL AND c.relname LIKE 'pg_%')
        ORDER BY l.granted ASC, l.pid
        """
        let rows = try await client.query(sql)
        var results: [PostgresLockInfo] = []
        for try await row in rows {
            let row = row.makeRandomAccess()
            results.append(PostgresLockInfo(
                pid: row[data: "pid"].int32 ?? 0,
                databaseName: row[data: "datname"].string,
                locktype: row[data: "locktype"].string ?? "",
                relation: row[data: "relation"].string,
                mode: row[data: "mode"].string ?? "",
                granted: row[data: "granted"].bool ?? true,
                blockingPid: row[data: "blocking_pid"].int32,
                query: row[data: "query"].string,
                state: row[data: "state"].string,
                waitDuration: row[data: "wait_seconds"].double
            ))
        }
        return results
    }

    func fetchTableStats() async throws -> [PostgresTableStat] {
        let sql = """
        SELECT schemaname, relname,
               COALESCE(seq_scan, 0) AS seq_scan,
               COALESCE(seq_tup_read, 0) AS seq_tup_read,
               COALESCE(idx_scan, 0) AS idx_scan,
               COALESCE(idx_tup_fetch, 0) AS idx_tup_fetch,
               COALESCE(n_live_tup, 0) AS n_live_tup,
               COALESCE(n_dead_tup, 0) AS n_dead_tup,
               last_vacuum, last_autovacuum,
               last_analyze, last_autoanalyze
        FROM pg_stat_user_tables
        ORDER BY n_dead_tup DESC
        LIMIT 50
        """
        let rows = try await client.query(sql)
        var results: [PostgresTableStat] = []
        for try await row in rows {
            let row = row.makeRandomAccess()
            guard let schema = row[data: "schemaname"].string,
                  let name = row[data: "relname"].string else { continue }
            results.append(PostgresTableStat(
                schemaName: schema,
                tableName: name,
                seqScan: row[data: "seq_scan"].int64 ?? 0,
                seqTupRead: row[data: "seq_tup_read"].int64 ?? 0,
                idxScan: row[data: "idx_scan"].int64 ?? 0,
                idxTupFetch: row[data: "idx_tup_fetch"].int64 ?? 0,
                nLiveTup: row[data: "n_live_tup"].int64 ?? 0,
                nDeadTup: row[data: "n_dead_tup"].int64 ?? 0,
                lastVacuum: row[data: "last_vacuum"].date,
                lastAutoVacuum: row[data: "last_autovacuum"].date,
                lastAnalyze: row[data: "last_analyze"].date,
                lastAutoAnalyze: row[data: "last_autoanalyze"].date
            ))
        }
        return results
    }

    func fetchReplicationStats() async throws -> [PostgresReplicationInfo] {
        let sql = """
        SELECT pid, usename, application_name, client_addr,
               state, sent_lsn::text, write_lsn::text,
               flush_lsn::text, replay_lsn::text,
               write_lag::text, flush_lag::text, replay_lag::text
        FROM pg_stat_replication
        ORDER BY pid
        """
        let rows = try await client.query(sql)
        var results: [PostgresReplicationInfo] = []
        for try await row in rows {
            let row = row.makeRandomAccess()
            results.append(PostgresReplicationInfo(
                pid: row[data: "pid"].int32 ?? 0,
                usename: row[data: "usename"].string ?? "",
                applicationName: row[data: "application_name"].string ?? "",
                clientAddr: row[data: "client_addr"].string,
                state: row[data: "state"].string ?? "",
                sentLsn: row[data: "sent_lsn"].string,
                writeLsn: row[data: "write_lsn"].string,
                flushLsn: row[data: "flush_lsn"].string,
                replayLsn: row[data: "replay_lsn"].string,
                writeLag: row[data: "write_lag"].string,
                flushLag: row[data: "flush_lag"].string,
                replayLag: row[data: "replay_lag"].string
            ))
        }
        return results
    }

    func fetchOperationProgress() async throws -> [PostgresOperationProgress] {
        // UNION ALL across all pg_stat_progress_* views
        let sql = """
        SELECT v.pid, a.datname, v.operation, v.phase,
               COALESCE(c.relname, '') AS relation,
               v.progress_pct,
               a.backend_start
        FROM (
            SELECT pid, 'VACUUM' AS operation, phase,
                   relid,
                   CASE WHEN heap_blks_total > 0
                        THEN ROUND(100.0 * heap_blks_scanned / heap_blks_total)
                        ELSE NULL END AS progress_pct
            FROM pg_stat_progress_vacuum
            UNION ALL
            SELECT pid, 'ANALYZE' AS operation, phase,
                   relid,
                   CASE WHEN sample_blks_total > 0
                        THEN ROUND(100.0 * sample_blks_scanned / sample_blks_total)
                        ELSE NULL END AS progress_pct
            FROM pg_stat_progress_analyze
            UNION ALL
            SELECT pid, 'CREATE INDEX' AS operation, phase,
                   relid,
                   CASE WHEN blocks_total > 0
                        THEN ROUND(100.0 * blocks_done / blocks_total)
                        ELSE NULL END AS progress_pct
            FROM pg_stat_progress_create_index
            UNION ALL
            SELECT pid, 'CLUSTER' AS operation, phase,
                   relid,
                   CASE WHEN heap_blks_total > 0
                        THEN ROUND(100.0 * heap_blks_scanned / heap_blks_total)
                        ELSE NULL END AS progress_pct
            FROM pg_stat_progress_cluster
            UNION ALL
            SELECT pid, 'COPY' AS operation, phase,
                   relid,
                   CASE WHEN bytes_total > 0
                        THEN ROUND(100.0 * bytes_processed / bytes_total)
                        ELSE NULL END AS progress_pct
            FROM pg_stat_progress_copy
            UNION ALL
            SELECT pid, 'BASEBACKUP' AS operation, phase,
                   0 AS relid,
                   CASE WHEN backup_total > 0
                        THEN ROUND(100.0 * backup_streamed / backup_total)
                        ELSE NULL END AS progress_pct
            FROM pg_stat_progress_basebackup
        ) v
        JOIN pg_stat_activity a ON a.pid = v.pid
        LEFT JOIN pg_class c ON c.oid = v.relid AND v.relid > 0
        ORDER BY v.pid
        """
        let rows = try await client.query(sql)
        var results: [PostgresOperationProgress] = []
        for try await row in rows {
            let row = row.makeRandomAccess()
            results.append(PostgresOperationProgress(
                pid: row[data: "pid"].int32 ?? 0,
                operation: row[data: "operation"].string ?? "",
                phase: row[data: "phase"].string ?? "",
                databaseName: row[data: "datname"].string,
                relation: row[data: "relation"].string,
                progressPercent: row[data: "progress_pct"].double,
                startedAt: row[data: "backend_start"].date
            ))
        }
        return results
    }
}
