import Foundation
import PGLibpq

/// Column metadata and compact row encoding for a result spool.
///
/// Encoded row format, per cell: `0x00` (NULL) or `0x01` + UInt32-LE length + the value's text
/// bytes as the server sent them. ``PostgresCellFormatter/stringValue(oid:data:)`` turns those bytes
/// into the display text later.
public struct PostgresRowExtractor: Sendable {
    public init() {}

    /// Column metadata, with the type stored as `"NAME(OID)"` (`"INTEGER(23)"`) for type-aware
    /// decoding. `typeNames` names types the built-in table doesn't know (from
    /// ``PostgresClient/typeNames(for:)``).
    public static func columns(from columns: [PostgresColumn], typeNames: [UInt32: String] = [:]) -> [ColumnInfo] {
        columns.map { column in
            ColumnInfo(
                name: column.name,
                dataType: "\(typeName(column.typeOID, typeNames))(\(column.typeOID))",
                isPrimaryKey: false,
                isNullable: true,
                maxLength: nil
            )
        }
    }

    /// Column metadata of a row's result.
    public static func columns(from row: PostgresRow, typeNames: [UInt32: String] = [:]) -> [ColumnInfo] {
        columns(from: PostgresColumn.columns(of: row.result), typeNames: typeNames)
    }

    /// The type OID stored in a ``ColumnInfo/dataType`` produced by ``columns(from:typeNames:)`` (`"INTEGER(23)"` → 23).
    public static func oid(fromDataType dataType: String) -> UInt32? {
        guard let open = dataType.lastIndex(of: "("), let close = dataType.lastIndex(of: ")"), open < close else { return nil }
        return UInt32(dataType[dataType.index(after: open)..<close])
    }

    /// A type's name: the built-in table, then `typeNames`, else `UNKNOWN <oid>` (as before).
    public static func typeName(_ oid: UInt32, _ typeNames: [UInt32: String] = [:]) -> String {
        PGTypeNames.name(of: oid) ?? typeNames[oid] ?? "UNKNOWN \(oid)"
    }

    /// Reusable buffer for encoding many rows without an allocation per row.
    public final class EncodingContext {
        fileprivate var buffer: [UInt8] = []

        public init(initialCapacity: Int = 4096) {
            buffer.reserveCapacity(max(256, initialCapacity))
        }
    }

    /// Encodes a row and, when asked, its display texts, in one pass over the cells.
    public static func encodeBinaryRow(
        from row: PostgresRow,
        formatPreview: Bool,
        formatter: PostgresCellFormatter,
        formattingEnabled: Bool = true,
        context: EncodingContext? = nil
    ) -> (encodedRow: Data, preview: [String?]?) {
        let result = row.result
        var preview: [String?]? = formatPreview ? [] : nil
        preview?.reserveCapacity(result.columnCount)
        var buffer = context?.buffer ?? []
        buffer.removeAll(keepingCapacity: true)
        for column in 0..<result.columnCount {
            if result.isNull(row: row.index, column: column) {
                buffer.append(0x00)
                preview?.append(nil)
                continue
            }
            result.withCell(row: row.index, column: column) { bytes in
                buffer.append(0x01)
                withUnsafeBytes(of: UInt32(bytes.count).littleEndian) { buffer.append(contentsOf: $0) }
                buffer.append(contentsOf: bytes)
                if formatPreview {
                    let oid = result.columnType(column)
                    if formattingEnabled || oid == 1184 {
                        preview?.append(formatter.stringValue(oid: oid, bytes: bytes))
                    } else {
                        preview?.append(PostgresCellFormatter.cheapStringValue(for: row[column]))
                    }
                }
            }
        }
        context?.buffer = buffer
        return (Data(buffer), preview)
    }

    /// Each cell's text bytes; nil for NULL.
    public static func rawCellData(from row: PostgresRow) -> [Data?] {
        row.map { $0.bytes }
    }

    /// Each cell's text bytes and, when asked, display text.
    public static func extractRow(
        from row: PostgresRow,
        formatPreview: Bool,
        formatter: PostgresCellFormatter,
        formattingEnabled: Bool = true
    ) -> (rawCells: [Data?], preview: [String?]?) {
        let raw = rawCellData(from: row)
        guard formatPreview else { return (raw, nil) }
        let preview = row.map { cell in
            formattingEnabled ? formatter.stringValue(for: cell) : PostgresCellFormatter.cheapStringValue(for: cell)
        }
        return (raw, preview)
    }
}
