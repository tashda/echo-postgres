import Foundation
import NIOCore
import PostgresNIO

/// Synchronous, `Sendable` formatter that converts a ``PostgresCell`` to its display string.
///
/// Binary cells (everything PostgresNIO returns) are rendered by ``PostgresBinaryFormatter`` so the
/// output matches what Postgres prints for the same value. Use ``stringValue(oid:data:)`` for
/// values that were stored as raw bytes (for example a result spool): it produces exactly the same
/// text as ``stringValue(for:)`` does for the live cell.
public struct PostgresCellFormatter: Sendable {
    private let binary: PostgresBinaryFormatter

    /// - Parameter timeZone: Time zone for `timestamptz` values. Defaults to the system time zone.
    public init(timeZone: TimeZone = .current) {
        self.binary = PostgresBinaryFormatter(timeZone: timeZone)
    }

    /// Format a ``PostgresCell`` to its display string. Returns `nil` for SQL `NULL`.
    public nonisolated func stringValue(for cell: PostgresCell) -> String? {
        guard let buffer = cell.bytes else { return nil }
        if cell.format == .text {
            return Self.textFormatValue(buffer, dataType: cell.dataType)
        }
        return binary.string(oid: cell.dataType.rawValue, buffer: buffer)
    }

    /// Format a binary-format value stored as raw bytes. Returns `nil` for `nil` (SQL `NULL`).
    public nonisolated func stringValue(oid: UInt32, data: Data?) -> String? {
        guard let data else { return nil }
        return binary.string(oid: oid, data: data)
    }

    /// Format a binary-format value given as raw bytes.
    public nonisolated func stringValue(oid: UInt32, bytes: UnsafeRawBufferPointer) -> String {
        binary.string(oid: oid, bytes: bytes)
    }

    // MARK: - Cheap String (Fast Path)

    /// Fast path used when rich formatting is switched off: text-format and text-like cells are
    /// returned as-is, everything else goes through the binary formatter (which is still cheap).
    @Sendable
    public nonisolated static func cheapStringValue(for cell: PostgresCell) -> String? {
        guard let buffer = cell.bytes else { return nil }
        if cell.format == .text {
            return textFormatValue(buffer, dataType: cell.dataType)
        }
        return PostgresBinaryFormatter().string(oid: cell.dataType.rawValue, buffer: buffer)
    }

    private static func textFormatValue(_ buffer: ByteBuffer, dataType: PostgresDataType) -> String {
        let readableBytes = buffer.readableBytes
        guard readableBytes > 0 else { return "" }
        let raw = buffer.getString(at: buffer.readerIndex, length: readableBytes) ?? ""
        if dataType == .bool {
            if raw == "t" { return "true" }
            if raw == "f" { return "false" }
        }
        return raw
    }
}
