import Foundation

public struct IPAddress: Equatable, Hashable, Codable, Sendable {
    public let string: String

    public init(string: String) {
        self.string = string
    }
}

extension IPAddress: PostgresEncodable {
    public func postgresBind() -> PostgresBind { .text(string, typeOID: 869) }
}

extension IPAddress: PostgresTextDecodable {
    public static func decode(text: String) throws -> IPAddress { IPAddress(string: text) }
}
