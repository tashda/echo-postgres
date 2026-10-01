/// SSL mode matching libpq's `sslmode` parameter.
public enum PostgresSSLMode: String, Sendable, CaseIterable {
    /// No SSL/TLS encryption.
    case disable
    /// Try non-SSL first, then SSL if the server rejects the unencrypted connection.
    case allow
    /// Try SSL first, fall back to non-SSL if the server doesn't support it.
    case prefer
    /// Require SSL but don't verify the server certificate.
    case require
    /// Require SSL and verify that the server certificate is signed by a trusted CA.
    case verifyCA = "verify-ca"
    /// Require SSL, verify the CA, and verify that the server hostname matches the certificate.
    case verifyFull = "verify-full"
}
