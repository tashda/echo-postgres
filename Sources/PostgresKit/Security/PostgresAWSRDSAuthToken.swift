import Crypto
import Foundation

/// AWS credentials used to sign RDS IAM authentication tokens.
public struct AWSCredentials: Sendable, Equatable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }

    /// `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and optional `AWS_SESSION_TOKEN` from the environment.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> AWSCredentials? {
        guard let key = environment["AWS_ACCESS_KEY_ID"], let secret = environment["AWS_SECRET_ACCESS_KEY"], !key.isEmpty, !secret.isEmpty else {
            return nil
        }
        return AWSCredentials(accessKeyID: key, secretAccessKey: secret, sessionToken: environment["AWS_SESSION_TOKEN"])
    }
}

/// IAM database authentication tokens for Amazon RDS / Aurora PostgreSQL.
///
/// A token is a SigV4-presigned `connect` request, valid for 15 minutes for *new* connections. Use
/// ``passwordProvider(host:port:username:region:credentials:)`` as
/// ``PostgresConfiguration/passwordProvider``: sessions get a fresh token per connect and pools are
/// replaced before their token expires. RDS requires TLS for IAM authentication.
public enum PostgresAWSRDSAuthToken {
    /// Tokens are accepted for 15 minutes.
    public static let lifetime: TimeInterval = 900

    public static func generate(
        host: String,
        port: Int,
        username: String,
        region: String,
        credentials: AWSCredentials,
        date: Date = Date()
    ) -> String {
        let endpoint = "\(host):\(port)"
        let query = AWSSigV4.presignedQuery(
            method: "GET",
            host: endpoint,
            path: "/",
            parameters: [("Action", "connect"), ("DBUser", username)],
            service: "rds-db",
            region: region,
            credentials: credentials,
            date: date,
            expires: Int(lifetime),
            payloadHash: AWSSigV4.emptyPayloadHash
        )
        return "\(endpoint)/?\(query)"
    }

    /// A password provider that signs a new token on every call.
    public static func passwordProvider(
        host: String,
        port: Int,
        username: String,
        region: String,
        credentials: @escaping @Sendable () async throws -> AWSCredentials
    ) -> PostgresPasswordProvider {
        {
            let now = Date()
            let token = generate(host: host, port: port, username: username, region: region, credentials: try await credentials(), date: now)
            return PostgresCredential(password: token, expiresAt: now.addingTimeInterval(lifetime))
        }
    }
}

/// AWS Signature Version 4 query-string presigning.
enum AWSSigV4 {
    static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// The presigned query string (including `X-Amz-Signature`) for a request with only the `host` header signed.
    static func presignedQuery(
        method: String,
        host: String,
        path: String,
        parameters: [(String, String)],
        service: String,
        region: String,
        credentials: AWSCredentials,
        date: Date,
        expires: Int,
        payloadHash: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        let day = String(amzDate.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"

        var query = parameters + [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expires)),
            ("X-Amz-SignedHeaders", "host"),
        ]
        if let token = credentials.sessionToken { query.append(("X-Amz-Security-Token", token)) }
        let encoded: [(key: String, value: String)] = query.map { (key: uriEncode($0.0), value: uriEncode($0.1)) }
        let sorted = encoded.sorted { lhs, rhs in lhs.key == rhs.key ? lhs.value < rhs.value : lhs.key < rhs.key }
        let canonicalQuery = sorted.map { pair in pair.key + "=" + pair.value }.joined(separator: "&")

        let canonicalRequest = [method, path, canonicalQuery, "host:\(host)\n", "host", payloadHash].joined(separator: "\n")
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
        return canonicalQuery + "&X-Amz-Signature=" + signature
    }

    /// RFC 3986 encoding: everything except `A-Z a-z 0-9 - _ . ~` is percent-encoded.
    static func uriEncode(_ value: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8)
        var result = ""
        for byte in value.utf8 {
            if unreserved.contains(byte) {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
