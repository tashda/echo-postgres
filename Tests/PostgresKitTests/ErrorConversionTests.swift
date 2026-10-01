import XCTest
@testable import PostgresKit

/// Unit tests for PostgresError creation, conversion, SQL state detection,
/// constraint violation helpers, and debugging info. No database required.
final class ErrorConversionTests: PostgresKitTestCase {

    // MARK: - Error Creation

    func testBasicErrorCreation() throws {
        let error = PostgresError(message: "Test error message")
        XCTAssertEqual(error.message, "Test error message")
        XCTAssertNil(error.sqlState)
        XCTAssertNil(error.severity)
        XCTAssertEqual(error.description, "Test error message")
        XCTAssertFalse(error.isForeignKeyViolation)
        XCTAssertFalse(error.isUniqueViolation)
        XCTAssertFalse(error.isConstraintViolation)
        XCTAssertFalse(error.isDataTypeMismatch)
    }

    func testErrorWithSQLState() throws {
        let error = PostgresError(
            message: "Unique constraint violation",
            sqlState: "23505",
            severity: "ERROR"
        )
        XCTAssertEqual(error.message, "Unique constraint violation")
        XCTAssertEqual(error.sqlState, "23505")
        XCTAssertEqual(error.severity, "ERROR")
    }

    // MARK: - SQL State Detection

    func testUniqueViolationDetection() throws {
        let error = PostgresError(message: "duplicate key", sqlState: "23505", severity: "ERROR")
        XCTAssertTrue(error.isUniqueViolation)
        XCTAssertTrue(error.isConstraintViolation)
        XCTAssertFalse(error.isForeignKeyViolation)
        XCTAssertTrue(error.isSQLState("23505"))
        XCTAssertFalse(error.isSQLState("23503"))
    }

    func testForeignKeyViolationDetection() throws {
        let error = PostgresError(message: "Foreign key violation", sqlState: "23503", severity: "ERROR")
        XCTAssertTrue(error.isForeignKeyViolation)
        XCTAssertTrue(error.isConstraintViolation)
        XCTAssertFalse(error.isUniqueViolation)
        XCTAssertTrue(error.isSQLState("23503"))
    }

    func testRestrictViolationDetection() throws {
        let error = PostgresError(message: "Restrict violation", sqlState: "23001", severity: "ERROR")
        XCTAssertTrue(error.isForeignKeyViolation)
        XCTAssertTrue(error.isConstraintViolation)
        XCTAssertFalse(error.isUniqueViolation)
        XCTAssertTrue(error.isSQLState("23001"))
    }

    func testDataTypeMismatchDetection() throws {
        let error = PostgresError(message: "Data type mismatch", sqlState: "42804", severity: "ERROR")
        XCTAssertTrue(error.isDataTypeMismatch)
        XCTAssertFalse(error.isConstraintViolation)
        XCTAssertFalse(error.isForeignKeyViolation)
        XCTAssertFalse(error.isUniqueViolation)
        XCTAssertTrue(error.isSQLState("42804"))
    }

    // MARK: - Debug Info

    func testDebugInfoWithServerInfo() throws {
        let serverInfo = [
            "constraintName": "uk_email",
            "tableName": "users",
            "detail": "Key (email)=(test@example.com) already exists."
        ]
        let error = PostgresError(
            message: "Duplicate key error",
            sqlState: "23505",
            severity: "ERROR",
            serverInfo: serverInfo
        )

        let debugInfo = error.withDebugging()
        XCTAssertEqual(debugInfo.message, "Duplicate key error")
        XCTAssertEqual(debugInfo.sqlState, "23505")
        XCTAssertEqual(debugInfo.constraintName, "uk_email")
        XCTAssertEqual(debugInfo.tableName, "users")
        XCTAssertEqual(debugInfo.detail, "Key (email)=(test@example.com) already exists.")

        let description = debugInfo.description
        XCTAssertTrue(description.contains("Duplicate key error"))
        XCTAssertTrue(description.contains("23505"))
        XCTAssertTrue(description.contains("uk_email"))
        XCTAssertTrue(description.contains("users"))
    }

    func testDebugInfoWithoutServerInfo() throws {
        let error = PostgresError(message: "Simple error")
        let debugInfo = error.withDebugging()
        XCTAssertEqual(debugInfo.message, "Simple error")
        XCTAssertNil(debugInfo.sqlState)
    }



    // MARK: - Result Extensions

    func testResultExtensionsSuccess() throws {
        let result: Result<String, PostgresError> = .success("test")
        XCTAssertEqual(result.errorMessage, "No error")
        XCTAssertFalse(result.isConstraintViolation)
        XCTAssertFalse(result.isSQLState("23505"))
    }

    func testResultExtensionsFailure() throws {
        let result: Result<String, PostgresError> = .failure(
            PostgresError(message: "Test error", sqlState: "23505")
        )
        XCTAssertEqual(result.errorMessage, "Test error")
        XCTAssertTrue(result.isConstraintViolation)
        XCTAssertTrue(result.isSQLState("23505"))
    }



    // MARK: - executeWithEnhancedError

}
