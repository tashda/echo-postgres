import Foundation
import PostgresNIO
#if canImport(GSS)
import GSS
#elseif canImport(CGSSAPI)
import CGSSAPI
#endif

/// Kerberos sign-in (GSSAPI, and SSPI from Windows servers): the client side of libpq's `gss`
/// authentication. It uses the ticket the user already has (kinit, Ticket Viewer, an Active
/// Directory login) for the service principal `<service>@<host>`, `postgres@db.example.com` by
/// default. macOS uses Apple's GSS framework; Linux uses MIT Kerberos (libkrb5).
public enum PostgresKerberos {
    /// Whether this build can sign in with Kerberos.
    public static var isAvailable: Bool {
        #if canImport(GSS) || canImport(CGSSAPI)
        return true
        #else
        return false
        #endif
    }

    /// The factory PostgresNIO calls when a server asks for Kerberos; `nil` where Kerberos is not available.
    static func authenticatorFactory(serviceName: String, host: String) -> PostgresGSSAuthenticatorFactory? {
        #if canImport(GSS) || canImport(CGSSAPI)
        let principal = "\(serviceName)@\(host)"
        return { try GSSAPIAuthenticator(servicePrincipal: principal) }
        #else
        return nil
        #endif
    }
}

/// Why Kerberos sign-in failed, in words someone can act on, with the Kerberos library's own text.
public struct PostgresKerberosError: Error, LocalizedError, Sendable {
    public enum Kind: Sendable, Equatable {
        /// There is no ticket (no kinit, no Ticket Viewer sign-in).
        case noTicket
        /// The ticket has expired.
        case expired
        /// The realm has no principal for the database service (wrong host or service name).
        case unknownService
        /// The computer's clock differs too much from the KDC's.
        case clockSkew
        case other
    }

    public let kind: Kind
    public let message: String
    /// The GSSAPI major and minor status texts.
    public let details: String
    public var errorDescription: String? { details.isEmpty ? message : "\(message) (\(details))" }
}

#if canImport(GSS) || canImport(CGSSAPI)
/// One GSSAPI security context for one connection attempt.
final class GSSAPIAuthenticator: PostgresGSSAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private let principal: String
    private let target: gss_name_t
    private var context: gss_ctx_id_t?

    init(servicePrincipal: String) throws {
        principal = servicePrincipal
        var minor: OM_uint32 = 0
        var nameBuffer = gss_buffer_desc()
        let utf8 = Array(servicePrincipal.utf8)
        var imported: gss_name_t?
        let major = utf8.withUnsafeBufferPointer { bytes -> OM_uint32 in
            nameBuffer.length = bytes.count
            nameBuffer.value = UnsafeMutableRawPointer(mutating: bytes.baseAddress)
            return gss_import_name(&minor, &nameBuffer, GSSAPIAuthenticator.hostBasedService, &imported)
        }
        guard !Self.isError(major), let imported else {
            throw PostgresKerberosError(kind: .unknownService, message: "The Kerberos service name \(servicePrincipal) is not valid.",
                                        details: Self.statusText(major: major, minor: minor))
        }
        target = imported
    }

    deinit {
        var minor: OM_uint32 = 0
        if context != nil { _ = gss_delete_sec_context(&minor, &context, nil) }
        var name: gss_name_t? = target
        _ = gss_release_name(&minor, &name)
    }

    func initialToken() throws -> [UInt8] {
        try lock.withLock { try step(input: nil) } ?? []
    }

    func nextToken(for serverToken: [UInt8]) throws -> [UInt8]? {
        try lock.withLock { try step(input: serverToken) }
    }

    private func step(input: [UInt8]?) throws -> [UInt8]? {
        var minor: OM_uint32 = 0
        var output = gss_buffer_desc()
        var flags: OM_uint32 = 0
        let major: OM_uint32
        if let input {
            major = input.withUnsafeBufferPointer { bytes -> OM_uint32 in
                var inputBuffer = gss_buffer_desc(length: bytes.count, value: UnsafeMutableRawPointer(mutating: bytes.baseAddress))
                return gss_init_sec_context(&minor, nil, &context, target, nil, OM_uint32(GSS_C_MUTUAL_FLAG), 0, nil,
                                            &inputBuffer, nil, &output, &flags, nil)
            }
        } else {
            major = gss_init_sec_context(&minor, nil, &context, target, nil, OM_uint32(GSS_C_MUTUAL_FLAG), 0, nil,
                                         nil, nil, &output, &flags, nil)
        }
        defer { var releaseMinor: OM_uint32 = 0; _ = gss_release_buffer(&releaseMinor, &output) }
        guard !Self.isError(major) else {
            let (kind, message) = Self.message(major: major, minor: minor, principal: principal)
            throw PostgresKerberosError(kind: kind, message: message, details: Self.statusText(major: major, minor: minor))
        }
        guard output.length > 0, let value = output.value else { return nil }
        return Array(UnsafeRawBufferPointer(start: value, count: output.length))
    }

    // MARK: - Status

    /// GSS_C_NT_HOSTBASED_SERVICE (1.2.840.113554.1.2.1.4, `service@host`), built from its bytes so
    /// neither platform's global constant is needed. Allocated once, never freed.
    nonisolated(unsafe) private static let hostBasedService: gss_OID = {
        let bytes: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x12, 0x01, 0x02, 0x01, 0x04]
        let elements = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
        elements.copyMemory(from: bytes, byteCount: bytes.count)
        let oid = UnsafeMutablePointer<gss_OID_desc>.allocate(capacity: 1)
        oid.initialize(to: gss_OID_desc(length: OM_uint32(bytes.count), elements: elements))
        return oid
    }()

    /// GSS_ERROR: a calling or routine error.
    private static func isError(_ major: OM_uint32) -> Bool { major & 0xFFFF_0000 != 0 }

    /// The routine error (GSS_ROUTINE_ERROR >> 16): 7 is GSS_S_NO_CRED, 13 GSS_S_FAILURE.
    private static func routineError(_ major: OM_uint32) -> OM_uint32 { (major >> 16) & 0xFF }

    private static func message(major: OM_uint32, minor: OM_uint32, principal: String) -> (PostgresKerberosError.Kind, String) {
        let details = statusText(major: major, minor: minor).lowercased()
        // No ticket: GSS_S_NO_CRED, or how MIT ("No Kerberos credentials available", "Credentials cache
        // file ... not found") and Heimdal ("get-pricipal open(...): No such file") say it.
        let noTicket = routineError(major) == 7
            || details.contains("no credentials") || details.contains("no kerberos credentials")
            || (details.contains("cache") && details.contains("not found"))
            || details.contains("get-pricipal") || details.contains("get-principal")
        if noTicket {
            return (.noTicket, "No Kerberos ticket. Sign in to Kerberos first (kinit, or Ticket Viewer on a Mac).")
        }
        // MIT: "Server x not found in Kerberos database"; Heimdal (macOS): "LOOKING_UP_SERVER".
        if details.contains("not found in kerberos database") || details.contains("server not found")
            || details.contains("unknown server") || details.contains("looking_up_server") {
            return (.unknownService, "The Kerberos realm does not know the database service \(principal). Check the host name and the service name.")
        }
        if routineError(major) == 11 || details.contains("expired") {
            return (.expired, "The Kerberos ticket has expired. Sign in to Kerberos again (kinit).")
        }
        if details.contains("clock skew") {
            return (.clockSkew, "This computer's clock differs too much from the Kerberos server's.")
        }
        return (.other, "Kerberos sign-in failed for \(principal).")
    }

    private static func statusText(major: OM_uint32, minor: OM_uint32) -> String {
        var texts: [String] = []
        for (code, type) in [(major, Int32(GSS_C_GSS_CODE)), (minor, Int32(GSS_C_MECH_CODE))] where code != 0 {
            var context: OM_uint32 = 0
            repeat {
                var statusMinor: OM_uint32 = 0
                var text = gss_buffer_desc()
                _ = gss_display_status(&statusMinor, code, type, nil, &context, &text)
                if text.length > 0, let value = text.value {
                    texts.append(String(decoding: UnsafeRawBufferPointer(start: value, count: text.length), as: UTF8.self))
                }
                _ = gss_release_buffer(&statusMinor, &text)
            } while context != 0
        }
        return texts.joined(separator: "; ")
    }
}
#endif
