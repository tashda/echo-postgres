import Testing
@testable import PostgresKit

/// A key file problem keeps its kind through `PostgresError`, so Echo's sheet can ask for the key
/// password (round 23, KW1).
@Suite("Client certificate file errors")
struct PostgresTLSFileErrorTests {
    @Test func keepTheirKind() {
        let converted = PostgresError.from(PostgresTLSFileError(kind: .wrongKeyPassword, message: "The key password is wrong."))
        guard case .clientCertificate(let file)? = converted.connectionProblem else {
            Issue.record("no client certificate problem: \(converted)")
            return
        }
        #expect(file.kind == .wrongKeyPassword)
        #expect(converted.isConnectionError)
    }
}
