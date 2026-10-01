import Foundation
import PGLibpq

/// One row of a result. Cells are read in place from libpq's result (no copy until asked).
public struct PostgresRow: Sendable, RandomAccessCollection {
    public let result: PGResult
    public let index: Int

    public init(result: PGResult, index: Int) {
        self.result = result
        self.index = index
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { result.columnCount }
    public subscript(column: Int) -> PostgresCell { PostgresCell(result: result, row: index, column: column) }

    /// The cell of the first column with this name.
    public subscript(column name: String) -> PostgresCell? {
        (0..<result.columnCount).first { result.columnName($0) == name }.map { self[$0] }
    }

    /// The cell of the first column with this name (PostgresNIO's random-access form). With no such
    /// column, reading the cell fails.
    public subscript(name: String) -> PostgresCell {
        self[column: name] ?? PostgresCell(result: result, row: index, column: result.columnCount)
    }

    /// Reads the row's first columns as the given types: `row.decode((String, Int?).self)`, or
    /// `row.decode(String.self)` for one column.
    public func decode<each T: PostgresTextDecodable>(_ type: (repeat each T).Type) throws -> (repeat each T) {
        var column = 0
        func next<U: PostgresTextDecodable>(_: U.Type) throws -> U {
            defer { column += 1 }
            guard column < result.columnCount else {
                throw PostgresDecodingError(message: "The row has \(result.columnCount) columns; more were asked for")
            }
            return try self[column].decode(U.self)
        }
        return (repeat try next((each T).self))
    }

    /// Reads the first column as `type`.
    public func decode<T: PostgresTextDecodable>(_ type: T.Type) throws -> T {
        guard result.columnCount > 0 else { throw PostgresDecodingError(message: "The row has no columns") }
        return try self[0].decode(T.self)
    }

    /// Reads one column by name.
    public func decode<T: PostgresTextDecodable>(column name: String, as type: T.Type = T.self) throws -> T {
        guard let cell = self[column: name] else { throw PostgresDecodingError(message: "No column \(name)") }
        return try cell.decode(T.self)
    }
}

/// One cell: the server's text (or NULL), its column's name and type.
public struct PostgresCell: Sendable {
    public let result: PGResult
    public let row: Int
    public let column: Int

    var exists: Bool { column < result.columnCount }
    public var columnName: String { exists ? result.columnName(column) : "" }
    /// The column's type OID.
    public var dataType: UInt32 { exists ? result.columnType(column) : 0 }
    public var isNull: Bool { exists ? result.isNull(row: row, column: column) : true }

    /// The server's text; nil for NULL.
    public var string: String? { exists ? result.string(row: row, column: column) : nil }

    /// The text's bytes without copying, valid inside `body`; nil for NULL.
    public func withBytes<R>(_ body: (UnsafeRawBufferPointer?) throws -> R) rethrows -> R {
        if isNull { return try body(nil) }
        return try result.withCell(row: row, column: column) { try body($0) }
    }

    /// The text's bytes as `Data` (a copy); nil for NULL.
    public var bytes: Data? { withBytes { $0.map { Data($0) } } }

    public func decode<T: PostgresTextDecodable>(_ type: T.Type) throws -> T {
        guard exists else { throw PostgresDecodingError(message: "No such column") }
        guard let text = string else { return try T.decodeNull() }
        return try T.decode(text: text)
    }
}
