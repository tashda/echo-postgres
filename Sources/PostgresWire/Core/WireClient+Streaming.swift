import Foundation
import Logging
import PostgresNIO

// MARK: - Streaming API

/// Convenience streaming with formatting and progress callbacks.
///
/// Every row passes through the ``PostgresDataStream`` actor, so this path is meant for moderate
/// result sizes and simple consumers. High-volume clients (like a results grid) should iterate the
/// row sequence themselves with ``PostgresRowExtractor`` and ``PostgresCellFormatter`` and batch
/// their own UI updates.
extension PostgresWireClient {

    /// Execute a query with streaming and formatting
    public func streamQuery(
        _ sql: String,
        configuration: PostgresStreamConfiguration = .default,
        onUpdate: @escaping @Sendable (PostgresStreamUpdate) async -> Void,
        logger: Logger? = nil
    ) async throws -> PostgresStreamResult {
        let effectiveLogger = logger ?? self.logger
        let operationStart = Date().timeIntervalSinceReferenceDate
        effectiveLogger.debug("Starting streaming query")

        let dataStream = PostgresDataStream(configuration: configuration, logger: effectiveLogger, operationStart: operationStart)
        let progress = ProgressThrottle(configuration: configuration, start: operationStart)

        do {
            let rowSequence = try await query(WireQuery(sql: sql), logger: effectiveLogger)
            var processedRowCount = 0
            for try await row in rowSequence {
                await dataStream.appendRow(row)
                processedRowCount += 1
                if progress.shouldReport(rowCount: processedRowCount) {
                    await sendProgressUpdate(dataStream: dataStream, lastSentRowCount: progress.lastReportedRowCount, onUpdate: onUpdate)
                    progress.didReport(rowCount: processedRowCount)
                }
                if Task.isCancelled {
                    await dataStream.cancel()
                    throw CancellationError()
                }
            }
            if processedRowCount > progress.lastReportedRowCount {
                await sendProgressUpdate(dataStream: dataStream, lastSentRowCount: progress.lastReportedRowCount, onUpdate: onUpdate)
            }
            return try await complete(dataStream: dataStream, onUpdate: onUpdate, logger: effectiveLogger)
        } catch {
            await fail(dataStream: dataStream, error: error, onUpdate: onUpdate)
            throw error
        }
    }

    /// Execute a streaming query with automatic cursor management for large result sets.
    ///
    /// `sql` must be a single `SELECT`-like statement; it is wrapped in `DECLARE … CURSOR` inside its
    /// own transaction on one connection.
    public func streamQueryWithCursor(
        _ sql: String,
        configuration: PostgresStreamConfiguration = .default,
        onUpdate: @escaping @Sendable (PostgresStreamUpdate) async -> Void,
        logger: Logger? = nil
    ) async throws -> PostgresStreamResult {
        let effectiveLogger = logger ?? self.logger
        let operationStart = Date().timeIntervalSinceReferenceDate
        effectiveLogger.debug("Starting cursor streaming query")

        let statements = PostgresSQLSplitter.split(sql)
        guard statements.count == 1, let statement = statements.first else {
            throw PostgresStreamingError.cursorRequiresSingleStatement(statementCount: statements.count)
        }

        return try await withConnection { connection in
            let dataStream = PostgresDataStream(configuration: configuration, logger: effectiveLogger, operationStart: operationStart)
            let progress = ProgressThrottle(configuration: configuration, start: operationStart)
            let cursorName = "pgstream_cur_" + String(UUID().uuidString.prefix(8)).lowercased()

            do {
                _ = try await connection.query(WireQuery(sql: "BEGIN"), logger: effectiveLogger)
                _ = try await connection.query(WireQuery(sql: "DECLARE \(cursorName) NO SCROLL CURSOR FOR \(statement.text)"), logger: effectiveLogger)

                var fetchSize = max(1, configuration.initialPreviewRows)
                var totalFetched = 0
                while true {
                    let rows = try await connection.query(WireQuery(sql: "FETCH FORWARD \(fetchSize) FROM \(cursorName)"), logger: effectiveLogger)
                    var fetchedThisRound = 0
                    for try await row in rows {
                        await dataStream.appendRow(row)
                        fetchedThisRound += 1
                        totalFetched += 1
                    }
                    if fetchedThisRound == 0 { break }
                    if totalFetched >= configuration.initialPreviewRows {
                        fetchSize = max(1, configuration.streamingFetchSize)
                    }
                    if progress.shouldReport(rowCount: totalFetched) {
                        await sendProgressUpdate(dataStream: dataStream, lastSentRowCount: progress.lastReportedRowCount, onUpdate: onUpdate)
                        progress.didReport(rowCount: totalFetched)
                    }
                    if Task.isCancelled {
                        await dataStream.cancel()
                        throw CancellationError()
                    }
                }
                if totalFetched > progress.lastReportedRowCount {
                    await sendProgressUpdate(dataStream: dataStream, lastSentRowCount: progress.lastReportedRowCount, onUpdate: onUpdate)
                }

                _ = try await connection.query(WireQuery(sql: "CLOSE \(cursorName)"), logger: effectiveLogger)
                _ = try await connection.query(WireQuery(sql: "COMMIT"), logger: effectiveLogger)
                return try await complete(dataStream: dataStream, onUpdate: onUpdate, logger: effectiveLogger)
            } catch {
                effectiveLogger.debug("Cursor cleanup after error: \(error)")
                // ROLLBACK also closes the cursor, and works when the transaction already failed.
                _ = try? await connection.query(WireQuery(sql: "ROLLBACK"), logger: effectiveLogger)
                await fail(dataStream: dataStream, error: error, onUpdate: onUpdate)
                throw error
            }
        }
    }

    // MARK: - Private Helper Methods

    private func complete(
        dataStream: PostgresDataStream,
        onUpdate: @escaping @Sendable (PostgresStreamUpdate) async -> Void,
        logger: Logger
    ) async throws -> PostgresStreamResult {
        await dataStream.complete()
        let metrics = await dataStream.getMetrics()
        let columns = await dataStream.columns
        let totalRowCount = await dataStream.getLiveRowCount()
        await onUpdate(.completion(columns: columns, totalRowCount: totalRowCount, metrics: metrics))
        logger.debug("Streaming query completed: \(totalRowCount) rows in \(String(format: "%.3f", metrics.totalElapsed))s")
        return PostgresStreamResult(columns: columns, totalRowCount: totalRowCount, metrics: metrics)
    }

    private func fail(
        dataStream: PostgresDataStream,
        error: any Error,
        onUpdate: @escaping @Sendable (PostgresStreamUpdate) async -> Void
    ) async {
        await dataStream.fail(with: error)
        await onUpdate(.error(columns: await dataStream.columns, totalRowCount: await dataStream.getLiveRowCount(), error: error))
    }

    private func sendProgressUpdate(
        dataStream: PostgresDataStream,
        lastSentRowCount: Int,
        onUpdate: @escaping @Sendable (PostgresStreamUpdate) async -> Void
    ) async {
        let rowCount = await dataStream.getLiveRowCount()
        let newRowsRange = lastSentRowCount..<max(lastSentRowCount, rowCount)
        let update = PostgresStreamUpdate(
            columns: await dataStream.columns,
            appendedRows: await dataStream.getFormattedRows(in: newRowsRange),
            rawRows: await dataStream.getRawRows(in: newRowsRange),
            totalRowCount: rowCount,
            metrics: await dataStream.getMetrics(),
            rowRange: newRowsRange
        )
        await onUpdate(update)
    }
}

/// Errors raised by the convenience streaming API.
public enum PostgresStreamingError: Error, LocalizedError, Sendable {
    case cursorRequiresSingleStatement(statementCount: Int)

    public var errorDescription: String? {
        switch self {
        case .cursorRequiresSingleStatement(let count):
            return "Cursor streaming needs exactly one statement, got \(count)."
        }
    }
}

/// Decides when a progress update is due: after `liveCounterFrequency` rows or `progressThrottle`
/// seconds, whichever comes first. Used from a single task, so no locking.
private final class ProgressThrottle: @unchecked Sendable {
    private let rowInterval: Int
    private let timeInterval: TimeInterval
    private let enabled: Bool
    private var lastReportTime: TimeInterval
    private(set) var lastReportedRowCount = 0

    init(configuration: PostgresStreamConfiguration, start: TimeInterval) {
        self.rowInterval = max(1, configuration.liveCounterFrequency)
        self.timeInterval = max(0, configuration.progressThrottle)
        self.enabled = configuration.liveCounterEnabled
        self.lastReportTime = start
    }

    func shouldReport(rowCount: Int) -> Bool {
        guard enabled else { return false }
        if rowCount - lastReportedRowCount >= rowInterval { return true }
        return Date().timeIntervalSinceReferenceDate - lastReportTime >= timeInterval
    }

    func didReport(rowCount: Int) {
        lastReportedRowCount = rowCount
        lastReportTime = Date().timeIntervalSinceReferenceDate
    }
}
