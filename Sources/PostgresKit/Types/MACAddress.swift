import Foundation

public struct MACAddress: Equatable, Hashable, Codable, Sendable {
    public let string: String

    public init(string: String) {
        self.string = string
    }
}

extension MACAddress: PostgresEncodable {
    /// Sent as text; the server parses every MAC format it knows (`08:00:2b:01:02:03`,
    /// `08-00-2b-01-02-03`, `0800.2b01.0203` …) and rejects the rest.
    public func postgresBind() -> PostgresBind { .text(string, typeOID: 829) }
}

extension MACAddress: PostgresTextDecodable {
    public static func decode(text: String) throws -> MACAddress { MACAddress(string: text) }
}
