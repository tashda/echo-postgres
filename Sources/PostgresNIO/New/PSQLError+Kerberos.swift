// postgres-wire change to the PostgresNIO copy (see ThirdParty/postgres-nio/README.md).

extension PSQLError {
    /// Whether the server asked for Kerberos (GSSAPI or SSPI) and no authenticator was configured.
    public var serverRequestedKerberos: Bool {
        guard code == .unsupportedAuthMechanism else { return false }
        switch unsupportedAuthScheme {
        case .gss?, .sspi?, .kerberosV5?: return true
        default: return false
        }
    }
}
