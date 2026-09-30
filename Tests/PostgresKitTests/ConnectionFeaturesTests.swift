import Foundation
import Logging
import NIOConcurrencyHelpers
import XCTest
@testable import PostgresKit

/// SigV4 signing for RDS IAM tokens (no database needed).
final class AWSSigningTests: XCTestCase {
    func testPresignMatchesAWSDocumentedExample() {
        // "Authenticating Requests: Using Query Parameters (AWS Signature Version 4)", Amazon S3 docs.
        let date = ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")!
        let query = AWSSigV4.presignedQuery(
            method: "GET",
            host: "examplebucket.s3.amazonaws.com",
            path: "/test.txt",
            parameters: [],
            service: "s3",
            region: "us-east-1",
            credentials: AWSCredentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
            date: date,
            expires: 86400,
            payloadHash: "UNSIGNED-PAYLOAD"
        )
        XCTAssertTrue(query.hasSuffix("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"), query)
    }

    func testRDSTokenShape() {
        let date = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")!
        let token = PostgresAWSRDSAuthToken.generate(
            host: "db.abc.eu-north-1.rds.amazonaws.com", port: 5432, username: "app_user", region: "eu-north-1",
            credentials: AWSCredentials(accessKeyID: "AKID", secretAccessKey: "secret", sessionToken: "tok/en+"),
            date: date
        )
        XCTAssertTrue(token.hasPrefix("db.abc.eu-north-1.rds.amazonaws.com:5432/?Action=connect&DBUser=app_user&X-Amz-Algorithm=AWS4-HMAC-SHA256"))
        XCTAssertTrue(token.contains("X-Amz-Credential=AKID%2F20260930%2Feu-north-1%2Frds-db%2Faws4_request"))
        XCTAssertTrue(token.contains("X-Amz-Date=20260930T120000Z&X-Amz-Expires=900"))
        XCTAssertTrue(token.contains("X-Amz-Security-Token=tok%2Fen%2B"))
        XCTAssertNotNil(token.range(of: "X-Amz-Signature=[0-9a-f]{64}$", options: .regularExpression))
        XCTAssertEqual(AWSCredentials.fromEnvironment(["AWS_ACCESS_KEY_ID": "a", "AWS_SECRET_ACCESS_KEY": "b"]), AWSCredentials(accessKeyID: "a", secretAccessKey: "b"))
    }
}

/// Host selection, credential rotation, sslmode=allow, binary COPY and the text fallback.
final class ConnectionFeaturesTests: PostgresKitTestCase {
    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
    }

    private func configuration(_ modify: (inout PostgresConfiguration) -> Void) -> PostgresConfiguration {
        var configuration = TestEnv.configuration(applicationName: "ConnectionFeatures")
        modify(&configuration)
        return configuration
    }

    private func scalar(_ session: PostgresSessionConnection, _ sql: String) async throws -> String? {
        let result = try await session.queryResult(sql)
        return result.rows.first.flatMap { $0.first.flatMap(PostgresCellFormatter().stringValue(for:)) }
    }

    // MARK: - Multi-host

    func testSkipsUnreachableHostsAndChecksAttributes() async throws {
        let dead = PostgresHost(host: "127.0.0.1", port: 1)
        let config = configuration {
            $0.additionalHosts = [PostgresHost(host: $0.host, port: $0.port)]
            $0.host = dead.host
            $0.port = dead.port
            $0.connectTimeout = 3
            $0.targetSessionAttributes = .primary
        }
        let session = try await PostgresSessionConnection.connect(configuration: config, logger: logger)
        XCTAssertEqual(session.connectedHost.port, TestEnv.port, "the unreachable first host is skipped")
        await session.close()

        let preferStandby = try await PostgresSessionConnection.connect(configuration: configuration { $0.targetSessionAttributes = .preferStandby }, logger: logger)
        await preferStandby.close()

        do {
            _ = try await PostgresSessionConnection.connect(configuration: configuration { $0.targetSessionAttributes = .standby }, logger: logger)
            XCTFail("the test server is a primary")
        } catch let error as PostgresError {
            XCTAssertTrue(error.message.contains("target_session_attrs=standby"), error.message)
        }

        let readOnly = configuration {
            $0.targetSessionAttributes = .readOnly
            $0.additionalStartupParameters = ["default_transaction_read_only": "on"]
        }
        let readOnlySession = try await PostgresSessionConnection.connect(configuration: readOnly, logger: logger)
        let value = try await scalar(readOnlySession, "SHOW transaction_read_only")
        XCTAssertEqual(value, "on")
        await readOnlySession.close()

        let pooled = try await PostgresKit.PostgresClient.connect(configuration: config, logger: logger)
        defer { pooled.close() }
        let one = try await pooled.simpleQueryResult("SELECT 1")
        XCTAssertEqual(one.rows.count, 1)
    }

    // MARK: - Credentials

    func testPoolIsReplacedBeforeTheCredentialExpires() async throws {
        let calls = NIOLockedValueBox(0)
        let password = TestEnv.password
        let config = configuration {
            $0.password = "wrong"
            $0.passwordProvider = {
                calls.withLockedValue { $0 += 1 }
                // Inside the rotation margin, so the next use replaces the pool.
                return PostgresCredential(password: password, expiresAt: Date().addingTimeInterval(100))
            }
        }
        let client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: logger)
        defer { client.close() }
        XCTAssertEqual(calls.withLockedValue { $0 }, 1)
        let first = try await client.simpleQueryResult("SELECT 1")
        XCTAssertEqual(first.rows.count, 1)
        XCTAssertGreaterThanOrEqual(calls.withLockedValue { $0 }, 2, "the pool was rebuilt with a fresh credential")
        let second = try await client.simpleQueryResult("SELECT 2")
        XCTAssertEqual(second.rows.count, 1)

        let session = try await PostgresSessionConnection.connect(configuration: config, logger: logger)
        await session.close()
    }

    func testSSLModeAllowUsesPlainWhenAccepted() async throws {
        let client = try await PostgresKit.PostgresClient.connect(configuration: configuration { $0.sslMode = .allow }, logger: logger)
        defer { client.close() }
        XCTAssertEqual(client.wire.resolvedConfiguration.sslMode, .disable)
    }

    // MARK: - Binary COPY

    func testBinaryCopyRoundTrip() async throws {
        let client = try await PostgresKit.PostgresClient.connect(configuration: configuration { _ in }, logger: logger)
        defer { client.close() }
        let source = "copy_bin_src_\(UInt32.random(in: 0..<UInt32.max))"
        let target = "copy_bin_dst_\(UInt32.random(in: 0..<UInt32.max))"
        let columns = "id int, note text, amount numeric, at timestamptz, tags int[], doc jsonb, blob bytea, span interval, addr inet, uid uuid, flag bool"
        _ = try await client.simpleQueryResult("CREATE TABLE \(source) (\(columns))")
        _ = try await client.simpleQueryResult("CREATE TABLE \(target) (\(columns))")
        defer { Task { _ = try? await client.simpleQueryResult("DROP TABLE IF EXISTS \(source), \(target)") } }
        _ = try await client.simpleQueryResult("""
            INSERT INTO \(source) VALUES
              (1, 'tab\there, "quote"', 12345678901234567890.123, '2024-02-29 13:45:01.5+02', '{1,NULL,3}', '{"a": [1, {"b": null}]}',
               '\\x00ff', '1 day -02:00:00', '2001:db8::1', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', true),
              (2, '', 'NaN', 'infinity', '{}', 'null', '', '0', '10.0.0.1/8', NULL, false),
              (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
            """)

        let bulk = PostgresBulkCopy(client: client, logger: logger)
        var exported = Data()
        for try await chunk in try await bulk.copyOut(sql: "COPY \(source) TO STDOUT (FORMAT binary)") { exported.append(chunk) }
        XCTAssertTrue(exported.starts(with: BinaryCopyFormat.signature))

        let bytes = Array(exported)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            var index = 0
            while index < bytes.count {
                continuation.yield(Data(bytes[index..<min(index + 13, bytes.count)]))
                index += 13
            }
            continuation.finish()
        }
        try await bulk.copyIn(sql: "COPY \(target) FROM STDIN (FORMAT binary)", source: stream)

        let differences = try await client.simpleQueryResult("""
            SELECT count(*) FROM ((SELECT * FROM \(source) EXCEPT ALL SELECT * FROM \(target))
                                  UNION ALL (SELECT * FROM \(target) EXCEPT ALL SELECT * FROM \(source))) d
            """)
        XCTAssertEqual(try differences.rows.first?.decode(Int.self), 0, "the binary round trip keeps every value")
        let count = try await client.simpleQueryResult("SELECT count(*) FROM \(target)")
        XCTAssertEqual(try count.rows.first?.decode(Int.self), 3)
    }

    // MARK: - Types without a binary output function

    func testColumnsWithoutBinaryOutputFallBackToText() async throws {
        let session = try await PostgresSessionConnection.connect(configuration: configuration { _ in }, logger: logger)
        defer { Task { await session.close() } }
        let formatter = PostgresCellFormatter()
        var rows: [[String?]] = []
        var names: [String] = []
        for try await row in try await session.query("SELECT relname, relacl, relkind FROM pg_class WHERE relacl IS NOT NULL ORDER BY relname LIMIT 3") {
            if names.isEmpty { names = row.map(\.columnName) }
            rows.append(row.map(formatter.stringValue(for:)))
        }
        XCTAssertEqual(names, ["relname", "relacl", "relkind"])
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { ($0[1] ?? "").hasPrefix("{") && ($0[1] ?? "").contains("=") }, "\(rows)")

        let result = try await session.queryResult("SELECT relacl FROM pg_class WHERE relacl IS NOT NULL LIMIT 1")
        XCTAssertEqual(result.rows.count, 1)

        _ = try await session.queryResult("BEGIN")
        do {
            _ = try await session.queryResult("SELECT relacl FROM pg_class WHERE relacl IS NOT NULL LIMIT 1")
            XCTFail("inside a transaction the error cannot be retried")
        } catch let error as PostgresError {
            XCTAssertEqual(error.sqlState, "42883")
            XCTAssertEqual(error.hint, PostgresSessionConnection.binaryOutputHint)
        }
        _ = try await session.queryResult("ROLLBACK")
    }
}
