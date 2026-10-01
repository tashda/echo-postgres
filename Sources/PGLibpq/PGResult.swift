/// One `PGresult` (a chunk of rows, a command's completion, or an error), freed with it.
///
/// `@unchecked Sendable` (owner decision D25, the only one allowed): libpq documents a `PGresult` as
/// read-only once returned ("can be passed around freely between threads"), and nothing here
/// mutates it. Cell bytes stay valid for as long
/// as this object lives.
public final class PGResult: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) { self.pointer = pointer }

    deinit { PQclear(pointer) }

    public enum Status: Sendable, Equatable {
        /// Rows from a result set, `rowCount` of them (chunked rows mode).
        case rowsChunk
        /// The end of a result set; may carry the last rows and always the columns.
        case rowsDone
        /// A command without rows finished (`commandStatus`, `affectedRows`).
        case commandDone
        case emptyQuery
        case copyIn
        case copyOut
        /// The statement failed; `error` has the server's fields.
        case error
        case other(Int32)
    }

    public var status: Status {
        switch PQresultStatus(pointer) {
        case PGRES_TUPLES_CHUNK, PGRES_SINGLE_TUPLE: .rowsChunk
        case PGRES_TUPLES_OK: .rowsDone
        case PGRES_COMMAND_OK: .commandDone
        case PGRES_EMPTY_QUERY: .emptyQuery
        case PGRES_COPY_IN: .copyIn
        case PGRES_COPY_OUT: .copyOut
        case PGRES_FATAL_ERROR, PGRES_NONFATAL_ERROR, PGRES_BAD_RESPONSE: .error
        case let other: .other(Int32(other.rawValue))
        }
    }

    public var rowCount: Int { Int(PQntuples(pointer)) }
    public var columnCount: Int { Int(PQnfields(pointer)) }

    /// The command tag (`SELECT 3`, `INSERT 0 1`, `CREATE TABLE`).
    public var commandStatus: String { String(cString: PQcmdStatus(pointer)) }

    /// Rows affected by INSERT/UPDATE/DELETE/MERGE/SELECT/MOVE/FETCH/COPY; nil for other commands.
    public var affectedRows: Int? { Int(String(cString: PQcmdTuples(pointer))) }

    public func columnName(_ column: Int) -> String { String(cString: PQfname(pointer, Int32(column))) }
    public func columnType(_ column: Int) -> UInt32 { UInt32(PQftype(pointer, Int32(column))) }
    public func columnTypeModifier(_ column: Int) -> Int32 { PQfmod(pointer, Int32(column)) }
    /// The table and column the result column comes from (0 when it is computed).
    public func columnSource(_ column: Int) -> (tableOID: UInt32, column: Int) {
        (UInt32(PQftable(pointer, Int32(column))), Int(PQftablecol(pointer, Int32(column))))
    }

    public func isNull(row: Int, column: Int) -> Bool { PQgetisnull(pointer, Int32(row), Int32(column)) == 1 }

    /// The cell's text as the server sent it, without copying; valid while this result lives.
    /// Empty for NULL (check `isNull`).
    public func withCell<R>(row: Int, column: Int, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        let length = Int(PQgetlength(pointer, Int32(row), Int32(column)))
        return try body(UnsafeRawBufferPointer(start: PQgetvalue(pointer, Int32(row), Int32(column)), count: length))
    }

    /// The cell as a String; nil for NULL.
    public func string(row: Int, column: Int) -> String? {
        if isNull(row: row, column: column) { return nil }
        return withCell(row: row, column: column) { String(decoding: $0, as: UTF8.self) }
    }

    /// The server's error fields, for `.error` results.
    public var error: PGServerError? {
        status == .error ? PGServerError(result: pointer) : nil
    }
}
