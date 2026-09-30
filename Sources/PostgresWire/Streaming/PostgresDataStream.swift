import Foundation
import Logging
import PostgresNIO

/// Actor managing PostgreSQL data streaming with integrated formatting.
/// Prefer `PostgresRowExtractor` and `PostgresCellFormatter` for lower per-row overhead in new code.
///
/// Row indexes are absolute (0 = first row of the result). When more than `maxConcurrentRows` rows
/// have been received, the oldest rows are dropped from memory and are no longer returned.
public actor PostgresDataStream {

    // MARK: - Configuration

    private let configuration: PostgresStreamConfiguration
    private let logger: Logger
    private let operationStart: TimeInterval

    // MARK: - Data Storage

    /// Column information for the result set
    public private(set) var columns: [ColumnInfo] = []

    /// Raw row payloads still held in memory, starting at absolute row ``firstRetainedRowIndex``.
    private(set) public var rawRows: [ResultRowPayload] = []

    /// Formatted rows held in memory (same indexing as ``rawRows``); rows not formatted yet are all `nil`.
    public var formattedRows: [[String?]] {
        formattedStorage.map { $0 ?? Array(repeating: nil, count: columns.count) }
    }

    /// `nil` marks a row that has not been formatted yet (SQL NULLs are `nil` *inside* a row).
    private var formattedStorage: [[String?]?] = []

    /// Absolute index of `rawRows[0]`.
    public private(set) var firstRetainedRowIndex = 0

    /// Total number of rows processed
    private(set) public var totalRowCount: Int = 0

    // MARK: - State Management

    /// Current streaming state
    private(set) public var state: StreamState = .streaming

    /// Command tag from PostgreSQL when query completes
    private(set) public var commandTag: String?

    // MARK: - Formatting Engine

    private let formatterEngine: PostgresFormatterEngine

    private var maxConcurrentRows: Int { max(1, configuration.maxConcurrentRows) }

    // MARK: - Initialization

    public init(
        configuration: PostgresStreamConfiguration,
        logger: Logger,
        operationStart: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) {
        self.configuration = configuration
        self.logger = logger
        self.operationStart = operationStart
        self.formatterEngine = PostgresFormatterEngine(configuration: configuration)
    }

    // MARK: - Column Management

    /// Set column information (called once when first row is processed)
    public func setColumns(_ newColumns: [ColumnInfo]) async {
        guard columns.isEmpty else { return }
        columns = newColumns
        await formatterEngine.setColumns(newColumns)
    }

    // MARK: - Row Processing

    /// Process a single PostgreSQL row
    public func appendRow(_ row: PostgresRow) async {
        guard state == .streaming else { return }

        if columns.isEmpty {
            await setColumns(PostgresRowExtractor.columns(from: row))
        }

        let payload = convertRowToPayload(row, rowIndex: totalRowCount)
        rawRows.append(payload)
        if shouldFormatRowImmediately(rowIndex: totalRowCount) {
            formattedStorage.append(await formatterEngine.formatRow(payload))
        } else {
            formattedStorage.append(nil)
        }
        totalRowCount += 1
        enforceMemoryLimits()
    }

    /// Get formatted rows in a specific range (absolute indexes). Rows no longer in memory are skipped.
    public func getFormattedRows(in range: Range<Int>) async -> [[String?]] {
        let lower = max(range.lowerBound, firstRetainedRowIndex)
        let upper = min(range.upperBound, totalRowCount)
        guard lower < upper else { return [] }

        var result: [[String?]] = []
        result.reserveCapacity(upper - lower)
        for absolute in lower..<upper {
            let local = absolute - firstRetainedRowIndex
            if let formatted = formattedStorage[local] {
                result.append(formatted)
            } else if configuration.formattingEnabled {
                let formatted = await formatterEngine.formatRow(rawRows[local])
                formattedStorage[local] = formatted
                result.append(formatted)
            } else {
                result.append(Array(repeating: nil, count: columns.count))
            }
        }
        return result
    }

    /// Get raw rows in a specific range (absolute indexes). Rows no longer in memory are skipped.
    public func getRawRows(in range: Range<Int>) async -> [ResultRowPayload] {
        let lower = max(range.lowerBound, firstRetainedRowIndex)
        let upper = min(range.upperBound, totalRowCount)
        guard lower < upper else { return [] }
        return Array(rawRows[(lower - firstRetainedRowIndex)..<(upper - firstRetainedRowIndex)])
    }

    /// Get current row count for live counter
    public func getLiveRowCount() async -> Int {
        return totalRowCount
    }

    /// Get current metrics
    public func getMetrics() async -> PostgresStreamMetrics {
        let now = Date().timeIntervalSinceReferenceDate
        return PostgresStreamMetrics(
            batchRowCount: 0,
            loopElapsed: now - operationStart,
            decodeDuration: 0,
            totalElapsed: now - operationStart,
            cumulativeRowCount: totalRowCount,
            fetchRowCount: totalRowCount
        )
    }

    /// Mark streaming as completed
    public func complete(with commandTag: String? = nil) async {
        state = .completed
        self.commandTag = commandTag
        if configuration.formattingEnabled && configuration.formattingMode != .deferred {
            for local in formattedStorage.indices where formattedStorage[local] == nil {
                formattedStorage[local] = await formatterEngine.formatRow(rawRows[local])
            }
        }
    }

    /// Mark streaming as failed
    public func fail(with error: Error) async {
        state = .error
        logger.error("PostgreSQL streaming failed: \(error)")
    }

    /// Cancel streaming
    public func cancel() async {
        state = .cancelled
        logger.info("PostgreSQL streaming cancelled")
    }

    // MARK: - Private Helper Methods

    private func convertRowToPayload(_ row: PostgresRow, rowIndex: Int) -> ResultRowPayload {
        let cells = row.map { cell in
            let format = ResultCellPayload.Format(rawValue: UInt8(clamping: cell.format.rawValue)) ?? .text
            let data = cell.bytes.map { buffer in
                buffer.withUnsafeReadableBytes { Data($0) }
            }
            return ResultCellPayload(dataTypeOID: cell.dataType.rawValue, format: format, bytes: data)
        }
        return ResultRowPayload(cells: cells, rowIndex: rowIndex)
    }

    private func shouldFormatRowImmediately(rowIndex: Int) -> Bool {
        guard configuration.formattingEnabled else { return false }
        switch configuration.formattingMode {
        case .immediate: return true
        case .deferred: return false
        case .smart: return rowIndex < configuration.initialPreviewRows
        }
    }

    /// Drops the oldest rows once the retained count exceeds the limit by 10%, so trimming is
    /// amortised instead of an O(n) `removeFirst` per row.
    private func enforceMemoryLimits() {
        let slack = max(1, maxConcurrentRows / 10)
        guard rawRows.count > maxConcurrentRows + slack else { return }
        let rowsToRemove = rawRows.count - maxConcurrentRows
        rawRows.removeFirst(rowsToRemove)
        formattedStorage.removeFirst(rowsToRemove)
        firstRetainedRowIndex += rowsToRemove
        logger.debug("Enforced memory limits: removed \(rowsToRemove) rows")
    }
}
