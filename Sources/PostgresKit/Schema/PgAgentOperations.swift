import Foundation

/// A pgAgent job to create: steps run in order, schedules say when.
public struct PgAgentJobDefinition: Sendable, Hashable {
    public enum StepKind: String, Sendable, Hashable { case sql = "s", batch = "b" }
    public enum OnError: String, Sendable, Hashable { case fail = "f", succeed = "s", ignore = "i" }

    public struct Step: Sendable, Hashable {
        public var name: String
        public var kind: StepKind
        public var code: String
        /// For SQL steps: the database to run in (batch steps run in the agent's shell and ignore it).
        public var database: String
        public var onError: OnError
        public var isEnabled: Bool

        public init(name: String, kind: StepKind = .sql, code: String, database: String = "postgres",
                    onError: OnError = .fail, isEnabled: Bool = true) {
            self.name = name
            self.kind = kind
            self.code = code
            self.database = database
            self.onError = onError
            self.isEnabled = isEnabled
        }
    }

    /// Runs at every combination of the listed minutes, hours, weekdays (0 = Sunday), month days
    /// (1–31; 32 = last day) and months (1–12). An empty list means every value.
    public struct Schedule: Sendable, Hashable {
        public var name: String
        public var start: Date
        public var end: Date?
        public var minutes: [Int]
        public var hours: [Int]
        public var weekdays: [Int]
        public var monthDays: [Int]
        public var months: [Int]
        public var isEnabled: Bool

        public init(name: String, start: Date = Date(), end: Date? = nil, minutes: [Int] = [], hours: [Int] = [],
                    weekdays: [Int] = [], monthDays: [Int] = [], months: [Int] = [], isEnabled: Bool = true) {
            self.name = name
            self.start = start
            self.end = end
            self.minutes = minutes
            self.hours = hours
            self.weekdays = weekdays
            self.monthDays = monthDays
            self.months = months
            self.isEnabled = isEnabled
        }
    }

    public var name: String
    public var description: String
    /// The job class, e.g. "Routine Maintenance" (pgAgent ships five).
    public var jobClass: String
    public var isEnabled: Bool
    public var steps: [Step]
    public var schedules: [Schedule]

    public init(name: String, description: String = "", jobClass: String = "Routine Maintenance", isEnabled: Bool = true,
                steps: [Step], schedules: [Schedule] = []) {
        self.name = name
        self.description = description
        self.jobClass = jobClass
        self.isEnabled = isEnabled
        self.steps = steps
        self.schedules = schedules
    }
}

/// A job from `pgagent.pga_job` with its step and schedule counts.
public struct PgAgentJob: Sendable, Hashable {
    public let id: Int
    public let name: String
    public let jobClass: String
    public let isEnabled: Bool
    public let stepCount: Int
    public let scheduleCount: Int
}

public extension PostgresPgAgentClient {
    /// Creates the job with its steps and schedules in one transaction; returns the job ID.
    @discardableResult
    func createJob(_ job: PgAgentJobDefinition) async throws -> Int {
        let jobBinds = try [job.jobClass, job.name, job.description].map { try client.bind($0) } + [try client.bind(job.isEnabled)]
        let stepBinds = try job.steps.map { step in
            // pgAgent insists that batch steps name no database.
            try [step.name, step.kind.rawValue, step.code, step.kind == .batch ? "" : step.database, step.onError.rawValue]
                .map { try client.bind($0) }
                + [try client.bind(step.isEnabled)]
        }
        let scheduleBinds = try job.schedules.map { schedule in
            try [client.bind(schedule.name), client.bind(schedule.start)]
                + [schedule.end.map { try client.bind($0) } ?? PostgresBind.null]
                + [Self.mask(schedule.minutes, 0..<60), Self.mask(schedule.hours, 0..<24), Self.mask(schedule.weekdays, 0..<7),
                   Self.mask(schedule.monthDays, 1..<33), Self.mask(schedule.months, 1..<13)].map { try client.bind($0) }
                + [try client.bind(schedule.isEnabled)]
        }
        return try await client.withTransaction { connection in
            var jobID: Int?
            let created = try await connection.query("""
                INSERT INTO pgagent.pga_job (jobjclid, jobname, jobdesc, jobenabled)
                SELECT jclid, $2, $3, $4 FROM pgagent.pga_jobclass WHERE jclname = $1 RETURNING jobid
                """, binds: jobBinds)
            for try await id in created.decode(Int32.self) { jobID = Int(id) }
            guard let jobID else { throw PostgresKit.PostgresError.protocolError("No pgAgent job class named \(job.jobClass)") }
            let idBind = try client.bind(jobID)
            for binds in stepBinds {
                let rows = try await connection.query("""
                    INSERT INTO pgagent.pga_jobstep (jstjobid, jstname, jstkind, jstcode, jstdbname, jstonerror, jstenabled)
                    VALUES ($1::int, $2, $3::char, $4, $5::name, $6::char, $7)
                    """, binds: [idBind] + binds)
                for try await _ in rows {}
            }
            for binds in scheduleBinds {
                let rows = try await connection.query("""
                    INSERT INTO pgagent.pga_schedule (jscjobid, jscname, jscstart, jscend, jscminutes, jschours, jscweekdays,
                                                      jscmonthdays, jscmonths, jscenabled)
                    VALUES ($1::int, $2, $3, $4, $5::boolean[], $6::boolean[], $7::boolean[], $8::boolean[], $9::boolean[], $10)
                    """, binds: [idBind] + binds)
                for try await _ in rows {}
            }
            return jobID
        }
    }

    func listJobs() async throws -> [PgAgentJob] {
        try await client.withConnection { connection in
            let rows = try await connection.query("""
                SELECT j.jobid, j.jobname, c.jclname, j.jobenabled,
                       (SELECT count(*) FROM pgagent.pga_jobstep s WHERE s.jstjobid = j.jobid),
                       (SELECT count(*) FROM pgagent.pga_schedule s WHERE s.jscjobid = j.jobid)
                FROM pgagent.pga_job j JOIN pgagent.pga_jobclass c ON c.jclid = j.jobjclid
                ORDER BY j.jobid
                """, binds: [])
            var jobs: [PgAgentJob] = []
            for try await (id, name, jobClass, enabled, steps, schedules) in rows.decode((Int32, String, String, Bool, Int64, Int64).self) {
                jobs.append(PgAgentJob(id: Int(id), name: name, jobClass: jobClass, isEnabled: enabled,
                                       stepCount: Int(steps), scheduleCount: Int(schedules)))
            }
            return jobs
        }
    }

    func setEnabled(jobID: Int, enabled: Bool) async throws {
        let binds = [try client.bind(enabled), try client.bind(jobID)]
        try await client.withConnection { connection in
            for try await _ in try await connection.query("UPDATE pgagent.pga_job SET jobenabled = $1 WHERE jobid = $2::int", binds: binds) {}
        }
    }

    /// Deletes the job; its steps, schedules and logs go with it.
    func deleteJob(id: Int) async throws {
        let bind = try client.bind(id)
        try await client.withConnection { connection in
            for try await _ in try await connection.query("DELETE FROM pgagent.pga_job WHERE jobid = $1::int", binds: [bind]) {}
        }
    }

    /// pgAgent's boolean mask as an array literal: `{t,f,…}` with `true` at each listed value.
    internal static func mask(_ values: [Int], _ range: Range<Int>) -> String {
        "{" + range.map { values.contains($0) ? "t" : "f" }.joined(separator: ",") + "}"
    }
}
