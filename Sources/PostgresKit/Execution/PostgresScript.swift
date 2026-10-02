import Foundation

/// One step of a SQL script as psql would run it.
public enum PostgresScriptStep: Sendable, Equatable {
    /// A statement without its trailing semicolon.
    case statement(String, line: Int)
    /// `COPY … FROM stdin` followed by its inline data (up to the `\.` line, not included).
    case copy(statement: String, data: String, line: Int)
    /// A psql meta-command such as `\connect db` or `\restrict key`. Not run by the driver.
    case metaCommand(String, line: Int)
}

/// Splits psql scripts and plain-format pg_dump output into steps. Lines starting with `\` are psql
/// meta-commands; a `COPY … FROM stdin;` line is followed by its data up to a `\.` line (both as
/// pg_dump writes them, on their own lines). Everything else is split by ``PostgresSQLSplitter``.
public enum PostgresScript {
    public static func steps(in script: String) -> [PostgresScriptStep] {
        let lines = script.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var steps: [PostgresScriptStep] = []
        var sql: [Substring] = []
        var sqlStartLine = 1
        var index = 0

        func flushSQL() {
            defer { sql = [] }
            guard !sql.isEmpty else { return }
            let text = sql.joined(separator: "\n")
            var line = sqlStartLine
            var position = text.startIndex
            for statement in PostgresSQLSplitter.split(text) {
                line += text[position..<statement.range.lowerBound].reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
                position = statement.range.lowerBound
                steps.append(.statement(statement.text, line: line))
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\\") {
                flushSQL()
                steps.append(.metaCommand(trimmed, line: index + 1))
                index += 1
                sqlStartLine = index + 1
            } else if trimmed.hasSuffix(";"), isCopyFromStdin(String(trimmed.dropLast())) {
                flushSQL()
                let copyLine = index + 1
                var data = ""
                index += 1
                while index < lines.count, lines[index] != "\\." {
                    data += lines[index] + "\n"
                    index += 1
                }
                index += 1
                steps.append(.copy(statement: String(trimmed.dropLast()), data: data, line: copyLine))
                sqlStartLine = index + 1
            } else {
                if sql.isEmpty { sqlStartLine = index + 1 }
                sql.append(line)
                index += 1
            }
        }
        flushSQL()
        return steps
    }

    static func isCopyFromStdin(_ statement: String) -> Bool {
        let words = statement.uppercased().split(whereSeparator: { $0.isWhitespace })
        guard words.first == "COPY", let from = words.lastIndex(of: "FROM"), from + 1 < words.count else { return false }
        return words[from + 1].hasPrefix("STDIN")
    }
}

public struct PostgresScriptSummary: Sendable {
    public let statementsRun: Int
    public let copiesRun: Int
    /// psql meta-commands that were skipped (`\connect`, `\restrict`, …).
    public let skippedMetaCommands: [String]
}

/// Error from ``PostgresScriptClient/run(_:progress:)`` naming the failed step and its line.
public struct PostgresScriptRunError: Error, CustomStringConvertible, Sendable {
    public let step: Int
    public let line: Int
    public let underlying: String
    public var description: String { "Step \(step + 1) (line \(line)) failed: \(underlying)" }
}

/// Runs psql scripts and plain pg_dump output through the driver: statements on one connection (so
/// `SET` and `set_config` carry over), `COPY … FROM stdin` data through the COPY protocol.
public struct PostgresScriptClient: Sendable {
    internal let client: PostgresClient

    @discardableResult
    public func run(_ script: String, progress: (@Sendable (_ step: Int, _ of: Int) -> Void)? = nil) async throws -> PostgresScriptSummary {
        let steps = PostgresScript.steps(in: script)
        let client = self.client
        return try await client.withConnection { connection in
            var statements = 0, copies = 0
            var skipped: [String] = []
            for (index, step) in steps.enumerated() {
                progress?(index + 1, steps.count)
                do {
                    switch step {
                    case .statement(let sql, _):
                        _ = try await connection.queryResult(sql)
                        statements += 1
                    case .copy(let sql, let data, _):
                        try await PostgresBulkCopy(client: client, logger: client.logger).copyIn(sql: sql, source: AsyncStream<Data> { continuation in
                            continuation.yield(Data(data.utf8))
                            continuation.finish()
                        })
                        copies += 1
                    case .metaCommand(let command, _):
                        skipped.append(command)
                    }
                } catch {
                    throw PostgresScriptRunError(step: index, line: step.line, underlying: String(reflecting: error))
                }
            }
            return PostgresScriptSummary(statementsRun: statements, copiesRun: copies, skippedMetaCommands: skipped)
        }
    }

    @discardableResult
    public func run(contentsOf file: URL, progress: (@Sendable (_ step: Int, _ of: Int) -> Void)? = nil) async throws -> PostgresScriptSummary {
        try await run(String(contentsOf: file, encoding: .utf8), progress: progress)
    }
}

extension PostgresScriptStep {
    public var line: Int {
        switch self {
        case .statement(_, let line), .copy(_, _, let line), .metaCommand(_, let line): line
        }
    }
}
