import Foundation
#if canImport(GSS)
import GSS
#elseif canImport(CGSSAPI)
import CGSSAPI
#endif

/// The user's Kerberos ticket as this process sees it (the default credential cache, or
/// `KRB5CCNAME`), for a sign-in sheet to show whose ticket will be used and until when.
public enum PostgresKerberosTicket: Sendable, Equatable {
    /// A usable ticket. `expiresAt` is nil when the ticket does not expire.
    case valid(principal: String, expiresAt: Date?)
    /// A ticket that has expired; the principal when the cache still names it.
    case expired(principal: String?)
    /// No ticket.
    case none
    /// This build has no Kerberos.
    case unavailable

    /// The principal's name without the realm (`alice` for `alice@CORP.EXAMPLE.COM`), which is
    /// the PostgreSQL role it usually maps to.
    public var userName: String? {
        switch self {
        case .valid(let principal, _), .expired(let principal?):
            return principal.split(separator: "@").first.map(String.init)
        default:
            return nil
        }
    }
}

extension PostgresKerberos {
    /// Reads the user's current ticket. Local only (the credential cache); it never asks the KDC.
    public static func currentTicket() -> PostgresKerberosTicket {
        #if canImport(GSS) || canImport(CGSSAPI)
        var minor: OM_uint32 = 0
        var credential: gss_cred_id_t?
        var lifetime: OM_uint32 = 0
        let acquired = gss_acquire_cred(&minor, nil, 0, nil, gss_cred_usage_t(GSS_C_INITIATE), &credential, nil, &lifetime)
        let routine = (acquired >> 16) & 0xFF
        guard acquired & 0xFFFF_0000 == 0, credential != nil else {
            return routine == 11 ? .expired(principal: nil) : .none // 11: GSS_S_CREDENTIALS_EXPIRED
        }
        defer { _ = gss_release_cred(&minor, &credential) }

        var name: gss_name_t?
        var remaining: OM_uint32 = 0
        let inquired = gss_inquire_cred(&minor, credential, &name, &remaining, nil, nil)
        defer { if name != nil { _ = gss_release_name(&minor, &name) } }
        let principal = name.flatMap(displayName)
        if inquired & 0xFFFF_0000 != 0 {
            return (inquired >> 16) & 0xFF == 11 ? .expired(principal: principal) : .none
        }
        guard let principal else { return .none }
        if remaining == 0 { return .expired(principal: principal) }
        return .valid(principal: principal, expiresAt: remaining == OM_uint32.max ? nil : Date().addingTimeInterval(TimeInterval(remaining)))
        #else
        return .unavailable
        #endif
    }

    #if canImport(GSS) || canImport(CGSSAPI)
    private static func displayName(_ name: gss_name_t) -> String? {
        var minor: OM_uint32 = 0
        var buffer = gss_buffer_desc()
        guard gss_display_name(&minor, name, &buffer, nil) & 0xFFFF_0000 == 0 else { return nil }
        defer { _ = gss_release_buffer(&minor, &buffer) }
        guard buffer.length > 0, let value = buffer.value else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: value, count: buffer.length), as: UTF8.self)
    }
    #endif
}
