import Foundation
import NIOCore
import NIOSSL
import Testing
@testable import PostgresWire

@Suite struct TLSKeyLogTests {
    @Test func keyLoggingIsOffUnlessAsked() {
        var configuration = TLSConfiguration.makeClientConfiguration()
        TLSKeyLog.apply(to: &configuration, environment: [:])
        #expect(configuration.keyLogCallback == nil)
        TLSKeyLog.apply(to: &configuration, environment: ["SSLKEYLOGFILE": "/tmp/keys"])
        #expect(configuration.keyLogCallback != nil)
    }

    @Test func linesAreAppendedOnePerSecret() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "keylog-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        TLSKeyLog.append(ByteBuffer(string: "CLIENT_TRAFFIC_SECRET_0 aa bb"), to: path)
        TLSKeyLog.append(ByteBuffer(string: "SERVER_TRAFFIC_SECRET_0 cc dd\n"), to: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "CLIENT_TRAFFIC_SECRET_0 aa bb\nSERVER_TRAFFIC_SECRET_0 cc dd\n")
    }
}
