import Foundation
import Logging
import NIOConcurrencyHelpers
import XCTest
@testable import PostgresKit

/// Client-certificate sign-in against echo-server-lab's `pg-17-tls-client-certificate` (the lab
/// hands back the CA, certificate and key), and no "run() hasn't been called yet" warning: the pool's
/// run() starts in a detached task, and whether it wins against the first lease depends on load
/// (the lab host saw it lose). `WireClient.pool()` now waits for it, so the warning can't appear
/// whichever way the timing falls; this test can't force the timing. Skipped without the server:
///
///     SERVERLAB_RECIPE=pg-17-tls-client-certificate Tests/with-lab.sh swift test --filter LabClientCertificateTests
final class LabClientCertificateTests: XCTestCase {
    /// Collects every message logged through the client's logger.
    private final class Recorder: @unchecked Sendable {
        let messages = NIOLockedValueBox<[String]>([])
    }

    private struct RecordingHandler: LogHandler {
        let recorder: Recorder
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
            recorder.messages.withLockedValue { $0.append(message.description) }
        }
    }

    func testSignsInWithTheCertificateWithoutThePoolWarning() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let ca = env["SERVERLAB_TLS_CA"], let certificate = env["SERVERLAB_TLS_CLIENT_CERT"], let key = env["SERVERLAB_TLS_CLIENT_KEY"],
              let host = env["POSTGRES_HOST"], let port = env["POSTGRES_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Start pg-17-tls-client-certificate with Tests/with-lab.sh")
        }
        let recorder = Recorder()
        let logger = Logger(label: "lab-client-certificate") { _ in RecordingHandler(recorder: recorder) }
        let configuration = PostgresConfiguration(
            host: host, port: port, database: "postgres", username: env["POSTGRES_USERNAME"] ?? "postgres",
            password: "not-the-password", sslMode: .verifyFull, sslRootCertPath: ca, sslCertPath: certificate, sslKeyPath: key,
            applicationName: "LabClientCertificateTests", connectTimeout: 15)
        let client = try await PostgresClient.connect(configuration: configuration, logger: logger)
        defer { client.close() }
        let result = try await client.simpleQueryResult("SELECT current_user::text")
        XCTAssertNotNil(result.rows.first)
        let warnings = recorder.messages.withLockedValue { $0 }.filter { $0.contains("hasn't been called yet") }
        XCTAssertEqual(warnings, [], "the first lease raced the pool's run()")
    }
}
