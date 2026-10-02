import Foundation

/// A scheduled job from `cron.job`.
public struct PostgresCronJob: Sendable, Hashable {
    public let id: Int64
    public let name: String?
    /// Cron syntax (`*/5 * * * *`) or an interval (`30 seconds`).
    public let schedule: String
    public let command: String
    public let database: String
    public let username: String
    public let isActive: Bool
}

/// One run of a job from `cron.job_run_details`.
public struct PostgresCronRun: Sendable, Hashable {
    public let id: Int64
    public let jobID: Int64
    /// `starting`, `running`, `sending`, `connecting`, `succeeded`, `failed`.
    public let status: String
    public let message: String?
    public let startTime: Date?
    public let endTime: Date?
}

public extension PostgresCronClient {
    /// Schedules `command` (SQL) under `name`, in `database` (default: the cron database).
    /// Scheduling an existing name replaces that job. Returns the job's ID.
    @discardableResult
    func schedule(name: String, schedule: String, command: String, database: String? = nil) async throws -> Int64 {
        let binds = try [name, schedule, command].map { try client.bind($0) }
            + (database.map { [try client.bind($0)] } ?? [])
        let sql = database == nil
            ? "SELECT cron.schedule($1, $2, $3)"
            : "SELECT cron.schedule_in_database($1, $2, $3, $4)"
        return try await client.withConnection { connection in
            let rows = try await connection.query(sql, binds: binds)
            for try await id in rows.decode(Int64.self) { return id }
            throw PostgresKit.PostgresError.protocolError("cron.schedule returned no job ID")
        }
    }

    /// Removes the job named `name`; false when there was none.
    @discardableResult
    func unschedule(name: String) async throws -> Bool {
        let bind = try client.bind(name)
        return try await client.withConnection { connection in
            let rows = try await connection.query("SELECT cron.unschedule($1)", binds: [bind])
            for try await removed in rows.decode(Bool.self) { return removed }
            return false
        }
    }

    /// Pauses or resumes a job.
    func setActive(jobID: Int64, active: Bool) async throws {
        let binds = [try client.bind(Int(jobID)), try client.bind(active)]
        try await client.withConnection { connection in
            let rows = try await connection.query("SELECT cron.alter_job(job_id := $1, active := $2)", binds: binds)
            for try await _ in rows {}
        }
    }

    func listJobs() async throws -> [PostgresCronJob] {
        try await client.withConnection { connection in
            let rows = try await connection.query(
                "SELECT jobid, jobname, schedule, command, database, username, active FROM cron.job ORDER BY jobid", binds: [])
            var jobs: [PostgresCronJob] = []
            for try await (id, name, schedule, command, database, username, active)
                in rows.decode((Int64, String?, String, String, String, String, Bool).self) {
                jobs.append(PostgresCronJob(id: id, name: name, schedule: schedule, command: command,
                                            database: database, username: username, isActive: active))
            }
            return jobs
        }
    }

    /// The latest runs, newest first.
    func listRuns(limit: Int = 100) async throws -> [PostgresCronRun] {
        let bind = try client.bind(max(1, limit))
        return try await client.withConnection { connection in
            let rows = try await connection.query(
                "SELECT runid, jobid, status, return_message, start_time, end_time FROM cron.job_run_details ORDER BY runid DESC LIMIT $1",
                binds: [bind])
            var runs: [PostgresCronRun] = []
            for try await (id, jobID, status, message, start, end) in rows.decode((Int64, Int64, String, String?, Date?, Date?).self) {
                runs.append(PostgresCronRun(id: id, jobID: jobID, status: status, message: message, startTime: start, endTime: end))
            }
            return runs
        }
    }
}
