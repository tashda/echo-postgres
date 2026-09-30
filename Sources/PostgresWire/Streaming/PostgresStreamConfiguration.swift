@preconcurrency import Foundation

/// Configuration for PostgreSQL query streaming with formatting options
public struct PostgresStreamConfiguration: @unchecked Sendable {

    // MARK: - Streaming Performance

    /// Number of rows in the initial preview batch for responsive UI
    public var initialPreviewRows: Int = 500

    /// Number of rows to fetch in background batches
    public var streamingFetchSize: Int = 4096

    /// Maximum number of rows to keep in memory (for memory protection)
    public var maxConcurrentRows: Int = 100_000

    // MARK: - Live Counter

    /// Enable live row count updates during streaming
    public var liveCounterEnabled: Bool = true

    /// Send a progress update at least every N rows (values below 1 are treated as 1).
    ///
    /// Every update copies the new rows out of the ``PostgresDataStream`` actor, so small values make
    /// streaming noticeably slower. Updates are also sent every ``progressThrottle`` seconds.
    public var liveCounterFrequency: Int = 1_000

    // MARK: - Formatting Configuration

    /// Enable automatic data formatting
    public var formattingEnabled: Bool = true

    /// Formatting strategy for different phases of streaming
    public var formattingMode: FormattingMode = .smart

    /// Locale for number and date formatting
    public var locale: Locale = .current

    /// Display text for NULL values
    public var nullValueDisplay: String = "NULL"

    /// Display text for boolean true values
    public var booleanTrueDisplay: String = "true"

    /// Display text for boolean false values
    public var booleanFalseDisplay: String = "false"

    /// Timestamp formatting strategy
    public var timestampFormat: TimestampFormat = .auto

    /// Number precision and formatting strategy
    public var numberPrecision: NumberPrecision = .auto

    /// Custom formatters for specific data types
    public var customFormatters: [StreamingPostgresDataType: Formatter] = [:]

    // MARK: - Performance Tuning

    /// Throttle interval for progress updates to prevent UI flooding
    public var progressThrottle: TimeInterval = 0.1 // 100ms

    /// Enable incremental loading for large result sets.
    /// Advisory: the driver does not read this; it is carried for UI consumers.
    public var enableIncrementalLoading: Bool = true

    /// Size of incremental window for virtual scrolling.
    /// Advisory: the driver does not read this; it is carried for UI consumers.
    public var incrementalWindowSize: Int = 200

    // MARK: - Initialization

    public init() {}

    /// Default configuration optimized for performance and responsiveness
    public static let `default` = PostgresStreamConfiguration()

    /// High-performance configuration with minimal overhead
    public static let highPerformance = PostgresStreamConfiguration {
        $0.liveCounterEnabled = false
        $0.formattingEnabled = false
        $0.progressThrottle = 0.5
        $0.streamingFetchSize = 8192
    }

    /// Configuration optimized for large data sets
    public static let largeDataset = PostgresStreamConfiguration {
        $0.initialPreviewRows = 200
        $0.streamingFetchSize = 8192
        $0.liveCounterFrequency = 5_000
        $0.maxConcurrentRows = 50_000
        $0.enableIncrementalLoading = true
        $0.incrementalWindowSize = 100
    }
}

/// Formatting strategy for different phases of query execution
public enum FormattingMode: String, CaseIterable, Sendable {
    /// Format all rows immediately (highest memory usage)
    case immediate

    /// Format rows only when needed for display (lowest memory usage)
    case deferred

    /// Smart formatting: immediate for preview, deferred for background
    case smart
}

/// Timestamp formatting strategies
public enum TimestampFormat: Sendable {
    /// Auto-detect best format based on data
    case auto

    /// ISO 8601 format (YYYY-MM-DD HH:MM:SS)
    case iso8601

    /// Local system format
    case local

    /// Custom date formatter
    case custom(DateFormatter)

    /// Relative time (e.g., "2 hours ago")
    case relative
}

/// Number precision and formatting strategies
public enum NumberPrecision: Sendable {
    /// Auto-detect appropriate precision
    case auto

    /// Fixed number of decimal places
    case fixed(Int)

    /// Significant figures
    case significant(Int)

    /// Custom number formatter
    case custom(NumberFormatter)
}

/// PostgreSQL data types for custom formatting
public enum StreamingPostgresDataType: String, CaseIterable, Sendable {
    case boolean = "bool"
    case smallInt = "int2"
    case integer = "int4"
    case bigInt = "int8"
    case real = "float4"
    case double = "float8"
    case numeric = "numeric"
    case text = "text"
    case varchar = "varchar"
    case char = "char"
    case timestamp = "timestamp"
    case timestamptz = "timestamptz"
    case date = "date"
    case time = "time"
    case timetz = "timetz"
    case interval = "interval"
    case uuid = "uuid"
    case json = "json"
    case jsonb = "jsonb"
    case array = "array"
    case bytea = "bytea"
    case inet = "inet"
    case cidr = "cidr"
    case macaddr = "macaddr"
    case macaddr8 = "macaddr8"
    case point = "point"
    case line = "line"
    case box = "box"
    case path = "path"
    case polygon = "polygon"
    case circle = "circle"
    case unknown = "unknown"

    /// Initialize from PostgreSQL OID
    public init(oid: Int) {
        // Map common PostgreSQL OIDs to data types
        switch oid {
        case 16: self = .boolean
        case 21: self = .smallInt
        case 23: self = .integer
        case 20: self = .bigInt
        case 700: self = .real
        case 701: self = .double
        case 1700: self = .numeric
        case 25, 1043: self = .text
        case 18: self = .char
        case 1114: self = .timestamp
        case 1184: self = .timestamptz
        case 1082: self = .date
        case 1083: self = .time
        case 1266: self = .timetz
        case 1186: self = .interval
        case 2950: self = .uuid
        case 114: self = .json
        case 3802: self = .jsonb
        case 1007, 1015, 1016, 1008, 1009, 1028, 1021, 1022, 1000, 1001, 1020, 1002, 1005, 1003, 1006, 1017: self = .array
        case 17: self = .bytea
        case 869: self = .inet
        case 650: self = .cidr
        case 829: self = .macaddr
        case 774: self = .macaddr8
        case 600: self = .point
        case 628: self = .line
        case 603: self = .box
        case 602: self = .path
        case 604: self = .polygon
        case 718: self = .circle
        default: self = .unknown
        }
    }
}

public extension PostgresStreamConfiguration {
    /// Create configuration with modifications
    init(modify: (inout PostgresStreamConfiguration) -> Void) {
        self.init()
        modify(&self)
    }
}