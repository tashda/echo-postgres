import Crypto
import Foundation

/// Client-side password hashing, as `psql`'s `\password` does, so the plain-text password never
/// appears in SQL text (and therefore not in server logs when `log_statement` covers DDL).
public enum PostgresPasswordHashing {

    /// A SCRAM-SHA-256 verifier in the form Postgres stores in `pg_authid`
    /// (`SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>`). Passing it as the password in
    /// `CREATE ROLE … PASSWORD` stores it as-is.
    ///
    /// Returns `nil` for passwords with non-ASCII characters: the server normalises those with SASLprep,
    /// and sending the plain text lets the server produce a verifier that is guaranteed to match.
    public static func scramSHA256Verifier(
        password: String,
        iterations: Int = 4096,
        salt: [UInt8]? = nil
    ) -> String? {
        guard password.unicodeScalars.allSatisfy(\.isASCII), iterations > 0 else { return nil }
        let saltBytes = salt ?? randomSalt()
        let passwordKey = SymmetricKey(data: Array(password.utf8))

        // SaltedPassword = Hi(password, salt, iterations) — PBKDF2 with HMAC-SHA-256.
        var block = Array(HMAC<SHA256>.authenticationCode(for: saltBytes + [0, 0, 0, 1], using: passwordKey))
        var salted = block
        if iterations > 1 {
            for _ in 1..<iterations {
                block = Array(HMAC<SHA256>.authenticationCode(for: block, using: passwordKey))
                for index in salted.indices { salted[index] ^= block[index] }
            }
        }

        let saltedKey = SymmetricKey(data: salted)
        let clientKey = Array(HMAC<SHA256>.authenticationCode(for: Array("Client Key".utf8), using: saltedKey))
        let storedKey = Array(SHA256.hash(data: clientKey))
        let serverKey = Array(HMAC<SHA256>.authenticationCode(for: Array("Server Key".utf8), using: saltedKey))

        return "SCRAM-SHA-256$\(iterations):\(Data(saltBytes).base64EncodedString())$"
            + "\(Data(storedKey).base64EncodedString()):\(Data(serverKey).base64EncodedString())"
    }

    private static func randomSalt() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

extension PostgresClient {
    /// `PASSWORD '…'` for role DDL: a client-side SCRAM verifier when `hash` is true (and the password
    /// is ASCII), otherwise the escaped plain text.
    func passwordClause(_ password: String, hash: Bool) -> String {
        if hash, let verifier = PostgresPasswordHashing.scramSHA256Verifier(password: password) {
            return "PASSWORD \(quoteLiteral(verifier))"
        }
        return "PASSWORD \(quoteLiteral(password))"
    }
}
