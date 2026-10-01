import Foundation
import PGLibpq

/// All rows of one statement plus its command tag.
public struct PostgresQueryResult: Sendable, RandomAccessCollection {
    public let metadata: PostgresQueryMetadata
    public let rows: [PostgresRow]

    public init(metadata: PostgresQueryMetadata, rows: [PostgresRow]) {
        self.metadata = metadata
        self.rows = rows
    }

    public var startIndex: Int { rows.startIndex }
    public var endIndex: Int { rows.endIndex }
    public subscript(position: Int) -> PostgresRow { rows[position] }
}

/// A statement's command tag (`SELECT 3`, `INSERT 0 1`, `CREATE TABLE`), split up.
public struct PostgresQueryMetadata: Sendable, Equatable {
    /// The command (`SELECT`, `INSERT`, `CREATE TABLE`).
    public let command: String
    /// The OID of an inserted row (always 0 since PostgreSQL 12).
    public var oid: Int?
    /// Rows the command returned or changed, for commands that report it.
    public var rows: Int?
    /// The tag as the server sent it.
    public let tag: String

    public init(tag: String) {
        self.tag = tag
        let parts = tag.split(separator: " ")
        let numbers = parts.reversed().prefix { Int($0) != nil }.reversed().compactMap { Int($0) }
        command = parts.dropLast(numbers.count).joined(separator: " ")
        if command == "INSERT", numbers.count == 2 {
            oid = numbers[0]
            rows = numbers[1]
        } else {
            rows = numbers.last
        }
    }
}

/// Former PostgresNIO names, kept for Echo (Phase 3, 3.8).
public typealias WireQueryResult = PostgresQueryResult
public typealias WireQueryMetadata = PostgresQueryMetadata
