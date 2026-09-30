import NIOCore
import XCTest
@testable import PostgresNIO

/// The Kerberos (GSSAPI/SSPI) path added to the PostgresNIO copy, with a fake authenticator.
final class GSSAuthenticationStateMachineTests: XCTestCase {
    private final class FakeAuthenticator: PostgresGSSAuthenticator, @unchecked Sendable {
        var received: [[UInt8]] = []
        let replies: [[UInt8]?]
        init(replies: [[UInt8]?]) { self.replies = replies }
        func initialToken() throws -> [UInt8] { [1, 2, 3] }
        func nextToken(for serverToken: [UInt8]) throws -> [UInt8]? {
            received.append(serverToken)
            return replies[received.count - 1]
        }
    }

    private struct Refused: Error {}

    private func machine(_ factory: PostgresGSSAuthenticatorFactory?) -> AuthenticationStateMachine {
        var machine = AuthenticationStateMachine(authContext: AuthContext(username: "alice", database: "postgres", gssAuthenticatorFactory: factory))
        _ = machine.start()
        return machine
    }

    private func buffer(_ bytes: [UInt8]) -> ByteBuffer { ByteBuffer(bytes: bytes) }

    func testGSSExchangeRelaysTokensUntilOk() {
        let fake = FakeAuthenticator(replies: [[9, 9], nil])
        var machine = machine { fake }
        guard case .sendGSSResponse(let first) = machine.authenticationMessageReceived(.gss) else { return XCTFail("first token") }
        XCTAssertEqual(first, [1, 2, 3])
        guard case .sendGSSResponse(let second) = machine.authenticationMessageReceived(.gssContinue(data: buffer([7]))) else { return XCTFail("second token") }
        XCTAssertEqual(second, [9, 9])
        guard case .wait = machine.authenticationMessageReceived(.gssContinue(data: buffer([8]))) else { return XCTFail("nothing more to send") }
        guard case .authenticated = machine.authenticationMessageReceived(.ok) else { return XCTFail("ok ends it") }
        XCTAssertEqual(fake.received, [[7], [8]])
    }

    func testSSPIUsesTheSameAuthenticator() {
        var machine = machine { FakeAuthenticator(replies: []) }
        guard case .sendGSSResponse = machine.authenticationMessageReceived(.sspi) else { return XCTFail("SSPI answers with GSS tokens") }
        guard case .authenticated = machine.authenticationMessageReceived(.ok) else { return XCTFail("ok") }
    }

    func testWithoutAnAuthenticatorKerberosIsRefusedAsBefore() {
        var machine = machine(nil)
        guard case .reportAuthenticationError(let error) = machine.authenticationMessageReceived(.gss) else { return XCTFail("refused") }
        XCTAssertEqual(error.code, .unsupportedAuthMechanism)
    }

    func testAnAuthenticatorFailureEndsAuthentication() {
        var machine = machine { throw Refused() }
        guard case .reportAuthenticationError(let error) = machine.authenticationMessageReceived(.gss) else { return XCTFail("error") }
        XCTAssertEqual(error.code, .saslError)
        XCTAssertTrue(machine.isComplete)
    }
}
