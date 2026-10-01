import Foundation
import PGLibpq
#if canImport(EchoTLS)
import EchoTLS
#endif

/// What one libpq connection is opened with: its keywords, and the converted client-certificate
/// files, which must live as long as the connection can reconnect (libpq reads them each time).
struct PostgresLibpqSetup: Sendable {
    var parameters: PGConnectionParameters
    #if canImport(EchoTLS)
    var clientCertificate: ClientCertificateFiles?
    #endif
}

extension PostgresConfiguration {
    /// A Kerberos sign-in: no password and no password provider (Echo leaves both out for
    /// Kerberos). Only then may libpq try Kerberos encryption (decision D7).
    var signsInWithKerberos: Bool {
        password == nil && passwordProvider == nil && kerberosServiceName != nil
    }

    /// The libpq keywords for this configuration (Phase 3, table 3.3). `password` is the one to
    /// use for this attempt (from `passwordProvider` when there is one).
    func libpqSetup(password: String?) async throws -> PostgresLibpqSetup {
        var parameters = PGConnectionParameters()
        try await setHosts(on: &parameters)
        parameters.set("dbname", database)
        parameters.set("user", username)
        parameters.set("password", password)
        parameters.set("application_name", applicationName ?? "Echo")
        parameters.set("client_encoding", "UTF8")
        parameters.set("connect_timeout", String(max(2, connectTimeout)))
        parameters.set("options", startupOptions)
        parameters.set("target_session_attrs", targetSessionAttributes.rawValue)
        parameters.set("load_balance_hosts", loadBalanceHosts ? "random" : "disable")
        parameters.set("krbsrvname", kerberosServiceName ?? "postgres")
        // No service name refuses Kerberos (libpq would otherwise answer a GSSAPI request with the
        // user's ticket).
        if kerberosServiceName == nil { parameters.set("require_auth", "!gss") }
        parameters.set("gssencmode", signsInWithKerberos ? "prefer" : "disable")
        parameters.set("sslmode", unixSocketPath == nil ? sslMode.rawValue : "disable")
        #if canImport(EchoTLS)
        var setup = PostgresLibpqSetup(parameters: parameters)
        try setTrust(on: &setup.parameters)
        setup.clientCertificate = try setClientCertificate(on: &setup.parameters)
        return setup
        #else
        parameters.set("sslrootcert", sslRootCertPath)
        parameters.set("sslcert", sslCertPath)
        parameters.set("sslkey", sslKeyPath)
        parameters.set("sslpassword", sslKeyPassword)
        return PostgresLibpqSetup(parameters: parameters)
        #endif
    }

    /// `-c` settings for every session: ISO dates and the postgres interval style (values are
    /// read as the server's text, decision D11), the configured timeouts, and extra parameters.
    var startupOptions: String {
        var settings: [(String, String)] = [("DateStyle", "ISO"), ("IntervalStyle", "postgres")]
        if let statementTimeout { settings.append(("statement_timeout", Self.milliseconds(statementTimeout))) }
        if let lockTimeout { settings.append(("lock_timeout", Self.milliseconds(lockTimeout))) }
        if let idleInTransactionSessionTimeout {
            settings.append(("idle_in_transaction_session_timeout", Self.milliseconds(idleInTransactionSessionTimeout)))
        }
        for (name, value) in additionalStartupParameters.sorted(by: { $0.key < $1.key }) {
            settings.append((name, value))
        }
        return settings.map { "-c \(Self.escapedOption("\($0.0)=\($0.1)"))" }.joined(separator: " ")
    }

    /// libpq's `options` splits on spaces; a backslash keeps a space or backslash literal.
    static func escapedOption(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if character == " " || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }

    /// `host`/`port` (comma lists for several hosts, in order). A Unix socket path names the
    /// socket file (`/tmp/.s.PGSQL.5432`), as PostgresNIO took it; libpq wants its folder and the
    /// port. With a Kerberos service host, libpq gets that name as `host` (it builds the principal
    /// from it) and the server's address as `hostaddr`.
    private func setHosts(on parameters: inout PGConnectionParameters) async throws {
        if let unixSocketPath {
            let url = URL(filePath: unixSocketPath)
            let name = url.lastPathComponent
            if name.hasPrefix(".s.PGSQL."), let socketPort = Int(name.dropFirst(".s.PGSQL.".count)) {
                parameters.set("host", url.deletingLastPathComponent().path)
                parameters.set("port", String(socketPort))
            } else {
                parameters.set("host", unixSocketPath)
                parameters.set("port", String(port))
            }
            return
        }
        let hosts = [PostgresHost(host: host, port: port)] + additionalHosts
        var names = hosts.map(\.host)
        if let kerberosServiceHost, !kerberosServiceHost.isEmpty, kerberosServiceHost != host {
            let address = try await Self.numericAddress(of: host)
            names[0] = kerberosServiceHost
            parameters.set("hostaddr", ([address] + Array(repeating: "", count: hosts.count - 1)).joined(separator: ","))
        }
        parameters.set("host", names.joined(separator: ","))
        parameters.set("port", hosts.map { String($0.port) }.joined(separator: ","))
    }

    /// The first address `host` resolves to, as text (libpq's `hostaddr` takes only numbers).
    @concurrent
    static func numericAddress(of host: String) async throws -> String {
        var hints = addrinfo()
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &list)
        guard status == 0, let first = list else {
            throw PostgresHostResolutionError(host: host, reason: String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(list) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            throw PostgresHostResolutionError(host: host, reason: "no numeric address")
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    #if canImport(EchoTLS)
    /// The CA file the user chose; without one, verify-ca and verify-full use the CAs this Mac
    /// trusts (the Keychain bundle, Phase 2). Other modes check nothing and read no file.
    private func setTrust(on parameters: inout PGConnectionParameters) throws {
        if let sslRootCertPath, !sslRootCertPath.isEmpty {
            parameters.set("sslrootcert", sslRootCertPath)
        } else if sslMode == .verifyCA || sslMode == .verifyFull {
            parameters.set("sslrootcert", try TrustBundle.currentPath())
        }
    }

    /// PEM, DER, encrypted keys and `.p12` files, as the PEM files libpq reads (Phase 2).
    private func setClientCertificate(on parameters: inout PGConnectionParameters) throws -> ClientCertificateFiles? {
        guard let sslCertPath, !sslCertPath.isEmpty else {
            parameters.set("sslcertmode", "disable")
            return nil
        }
        let files: ClientCertificateFiles
        do {
            files = try ClientCertificateFiles.make(certificatePath: sslCertPath, keyPath: sslKeyPath, password: sslKeyPassword)
        } catch {
            throw PostgresTLSFileError(error)
        }
        parameters.set("sslcert", files.certificatePath)
        parameters.set("sslkey", files.keyPath)
        parameters.set("sslpassword", files.keyPassword)
        return files
    }
    #endif
}

extension PostgresConfiguration {
    /// A connect failure as a PostgresError; when `target_session_attrs` turned every host down,
    /// it says so in Echo's words ("No server matched target_session_attrs=standby."), with
    /// libpq's reason after it.
    func connectError(_ error: any Error) -> PostgresError {
        let mapped = PostgresError.from(error)
        guard targetSessionAttributes != .any, let detail = mapped.detail?.lowercased() else { return mapped }
        let attributeRefusals = ["hot standby mode", "session is read-only", "session is not read-only", "server is in hot standby", "server is not in hot standby"]
        guard attributeRefusals.contains(where: detail.contains) else { return mapped }
        let reason = PostgresConnectionMessages.firstLine(of: mapped.detail ?? "", droppingPrefix: true)
        return PostgresError(
            message: "No server matched target_session_attrs=\(targetSessionAttributes.rawValue). \(reason)",
            serverInfo: mapped.detail.map { ["detail": $0] },
            isConnectionError: true
        )
    }
}

/// A host name could not be turned into an address (for a Kerberos service host).
public struct PostgresHostResolutionError: Error, LocalizedError, Sendable {
    public let host: String
    public let reason: String
    public var errorDescription: String? { "Could not find the address of \(host): \(reason)." }
}
