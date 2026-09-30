import Foundation
import Logging

/// Engine responsible for formatting PostgreSQL data into display strings.
///
/// Values are rendered by ``PostgresBinaryFormatter`` (the same code as ``PostgresCellFormatter``);
/// this actor only adds the presentation options of ``PostgresStreamConfiguration``: NULL and boolean
/// display text, custom formatters, number precision and timestamp style.
/// Prefer `PostgresCellFormatter` for lower per-cell overhead in new code.
public actor PostgresFormatterEngine {

    private let configuration: PostgresStreamConfiguration
    private let logger: Logger
    private let binary: PostgresBinaryFormatter
    private var columns: [ColumnInfo] = []
    private var formatters: [StreamingPostgresDataType: Formatter] = [:]

    public init(configuration: PostgresStreamConfiguration, logger: Logger = .init(label: "postgres-formatter")) {
        self.configuration = configuration
        self.logger = logger
        self.binary = PostgresBinaryFormatter()
        var formatters: [StreamingPostgresDataType: Formatter] = [:]
        for (dataType, formatter) in configuration.customFormatters {
            formatters[dataType] = formatter
        }
        self.formatters = formatters
    }

    /// Set column information for formatting context
    public func setColumns(_ newColumns: [ColumnInfo]) {
        self.columns = newColumns
    }

    /// Format a single row payload into display strings
    public func formatRow(_ payload: ResultRowPayload) async -> [String?] {
        payload.cells.map(formatCell)
    }

    // MARK: - Cell Formatting

    private func formatCell(_ cell: ResultCellPayload) -> String? {
        guard let data = cell.bytes else {
            return configuration.nullValueDisplay
        }
        let text = cell.format == .text
            ? String(decoding: data, as: UTF8.self)
            : binary.string(oid: cell.dataTypeOID, data: data)
        let dataType = StreamingPostgresDataType(oid: Int(cell.dataTypeOID))

        if let custom = formatters[dataType] {
            if let number = Double(text) { return custom.string(for: number) ?? text }
            return custom.string(for: text) ?? text
        }

        switch dataType {
        case .boolean where cell.format == .text:
            return text == "t" || text == "true" ? configuration.booleanTrueDisplay : configuration.booleanFalseDisplay
        case .boolean:
            return text == "true" ? configuration.booleanTrueDisplay : text == "false" ? configuration.booleanFalseDisplay : text
        case .real, .double, .numeric:
            return formatNumber(text)
        case .timestamp, .timestamptz, .date:
            return formatTemporal(cell, text: text, dataType: dataType)
        default:
            return text
        }
    }

    // MARK: - Presentation options

    private func formatNumber(_ text: String) -> String {
        let formatter: NumberFormatter
        switch configuration.numberPrecision {
        case .auto:
            return text
        case .fixed(let decimalPlaces):
            formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = decimalPlaces
        case .significant(let figures):
            formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumSignificantDigits = figures
        case .custom(let custom):
            formatter = custom
        }
        guard let value = Double(text) else { return text }
        return formatter.string(from: NSNumber(value: value)) ?? text
    }

    private func formatTemporal(_ cell: ResultCellPayload, text: String, dataType: StreamingPostgresDataType) -> String {
        if case .auto = configuration.timestampFormat { return text }
        guard cell.format == .binary, let data = cell.bytes, let date = Self.date(from: data, dataType: dataType) else {
            return text
        }
        switch configuration.timestampFormat {
        case .auto:
            return text
        case .iso8601:
            return ISO8601DateFormatter().string(from: date)
        case .local:
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = dataType == .date ? .none : .medium
            return formatter.string(from: date)
        case .custom(let formatter):
            return formatter.string(from: date)
        case .relative:
            // RelativeDateTimeFormatter is not available in Foundation on Linux.
            let interval = date.timeIntervalSince(Date())
            let seconds = abs(interval)
            let description: String
            if seconds < 60 {
                description = "\(Int(seconds)) seconds"
            } else if seconds < 3600 {
                description = "\(Int(seconds / 60)) minutes"
            } else if seconds < 86400 {
                description = "\(Int(seconds / 3600)) hours"
            } else {
                description = "\(Int(seconds / 86400)) days"
            }
            return interval < 0 ? "\(description) ago" : "in \(description)"
        }
    }

    /// Finite binary date / timestamp values as a `Date`.
    private static func date(from data: Data, dataType: StreamingPostgresDataType) -> Date? {
        let epoch: TimeInterval = 946_684_800
        if dataType == .date {
            guard data.count == 4 else { return nil }
            let days = Int32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
            guard days != .max, days != .min else { return nil }
            return Date(timeIntervalSince1970: epoch + Double(days) * 86_400)
        }
        guard data.count == 8 else { return nil }
        let microseconds = Int64(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) })
        guard microseconds != .max, microseconds != .min else { return nil }
        return Date(timeIntervalSince1970: epoch + Double(microseconds) / 1_000_000)
    }
}
