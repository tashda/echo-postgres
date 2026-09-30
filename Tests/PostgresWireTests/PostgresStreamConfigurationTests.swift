import XCTest
@testable import PostgresWire

final class PostgresStreamConfigurationTests: XCTestCase {

    // MARK: - Default configuration

    func testDefaultConfigurationValues() {
        let config = PostgresStreamConfiguration.default

        XCTAssertEqual(config.initialPreviewRows, 500)
        XCTAssertEqual(config.streamingFetchSize, 4096)
        XCTAssertEqual(config.maxConcurrentRows, 100_000)
        XCTAssertTrue(config.liveCounterEnabled)
        XCTAssertEqual(config.liveCounterFrequency, 1_000)
        XCTAssertTrue(config.formattingEnabled)
        XCTAssertEqual(config.formattingMode, .smart)
        XCTAssertEqual(config.progressThrottle, 0.1, accuracy: 0.001)
        XCTAssertTrue(config.enableIncrementalLoading)
        XCTAssertEqual(config.incrementalWindowSize, 200)
        XCTAssertEqual(config.nullValueDisplay, "NULL")
        XCTAssertEqual(config.booleanTrueDisplay, "true")
        XCTAssertEqual(config.booleanFalseDisplay, "false")
        XCTAssertTrue(config.customFormatters.isEmpty)
    }

    // MARK: - High-performance preset

    func testHighPerformancePreset() {
        let config = PostgresStreamConfiguration.highPerformance

        XCTAssertFalse(config.liveCounterEnabled)
        XCTAssertFalse(config.formattingEnabled)
        XCTAssertEqual(config.progressThrottle, 0.5, accuracy: 0.001)
        XCTAssertEqual(config.streamingFetchSize, 8192)
    }

    // MARK: - Large dataset preset

    func testLargeDatasetPreset() {
        let config = PostgresStreamConfiguration.largeDataset

        XCTAssertEqual(config.initialPreviewRows, 200)
        XCTAssertEqual(config.streamingFetchSize, 8192)
        XCTAssertEqual(config.liveCounterFrequency, 5_000)
        XCTAssertEqual(config.maxConcurrentRows, 50_000)
        XCTAssertTrue(config.enableIncrementalLoading)
        XCTAssertEqual(config.incrementalWindowSize, 100)
    }

    // MARK: - Custom modification initializer

    func testCustomModificationInitializer() {
        let config = PostgresStreamConfiguration { c in
            c.initialPreviewRows = 100
            c.liveCounterFrequency = 20
            c.formattingMode = .immediate
            c.nullValueDisplay = "<NULL>"
            c.booleanTrueDisplay = "YES"
            c.booleanFalseDisplay = "NO"
        }

        XCTAssertEqual(config.initialPreviewRows, 100)
        XCTAssertEqual(config.liveCounterFrequency, 20)
        XCTAssertEqual(config.formattingMode, .immediate)
        XCTAssertEqual(config.nullValueDisplay, "<NULL>")
        XCTAssertEqual(config.booleanTrueDisplay, "YES")
        XCTAssertEqual(config.booleanFalseDisplay, "NO")
    }

    func testCustomModification_PreservesDefaultsForUnchangedFields() {
        let config = PostgresStreamConfiguration { c in
            c.initialPreviewRows = 50
        }

        XCTAssertEqual(config.streamingFetchSize, 4096)
        XCTAssertEqual(config.maxConcurrentRows, 100_000)
        XCTAssertTrue(config.liveCounterEnabled)
        XCTAssertEqual(config.formattingMode, .smart)
    }

    // MARK: - FormattingMode enum

    func testFormattingModeAllCases() {
        let allCases = FormattingMode.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.immediate))
        XCTAssertTrue(allCases.contains(.deferred))
        XCTAssertTrue(allCases.contains(.smart))
    }

    func testFormattingModeRawValues() {
        XCTAssertEqual(FormattingMode.immediate.rawValue, "immediate")
        XCTAssertEqual(FormattingMode.deferred.rawValue, "deferred")
        XCTAssertEqual(FormattingMode.smart.rawValue, "smart")
    }

    // MARK: - StreamingPostgresDataType allCases

    func testStreamingPostgresDataTypeAllCasesNotEmpty() {
        XCTAssertFalse(StreamingPostgresDataType.allCases.isEmpty)
    }
}
