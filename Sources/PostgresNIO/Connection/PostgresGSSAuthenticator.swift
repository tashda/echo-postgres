// postgres-wire change to the PostgresNIO copy (see ThirdParty/postgres-nio/README.md).

/// Answers a server that asks for Kerberos: GSSAPI, or SSPI from a Windows server (which accepts
/// the same Kerberos tokens). PostgresNIO only relays the tokens; the Kerberos implementation
/// (Apple's GSS framework, MIT Kerberos) is supplied through the connection options'
/// `gssAuthenticatorFactory`.
public protocol PostgresGSSAuthenticator: AnyObject, Sendable {
    /// The first token to send to the server.
    func initialToken() throws -> [UInt8]
    /// The token to send for the server's `serverToken`, or `nil` when there is nothing more to send.
    func nextToken(for serverToken: [UInt8]) throws -> [UInt8]?
}

/// Makes a ``PostgresGSSAuthenticator`` for one connection attempt.
public typealias PostgresGSSAuthenticatorFactory = @Sendable () throws -> any PostgresGSSAuthenticator
