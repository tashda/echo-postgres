import Foundation
import PostgresWire

/// The binary COPY file format (`COPY … (FORMAT binary)`).
///
/// Layout: an 11-byte signature, a 32-bit flags field, a 32-bit header-extension length (and that many
/// bytes), then tuples — a 16-bit field count followed by (32-bit length, bytes) per field, `-1` for
/// NULL — and finally a 16-bit `-1` trailer. Field bytes are each type's binary send format, which is
/// exactly what PostgresNIO returns for result columns.
enum BinaryCopyFormat {
    static let signature: [UInt8] = [0x50, 0x47, 0x43, 0x4F, 0x50, 0x59, 0x0A, 0xFF, 0x0D, 0x0A, 0x00]

    static var header: Data {
        var data = Data(signature)
        data.append(contentsOf: [0, 0, 0, 0]) // flags: no OIDs
        data.append(contentsOf: [0, 0, 0, 0]) // no header extension
        return data
    }

    static var trailer: Data { Data([0xFF, 0xFF]) }

    static func appendTuple(_ fields: [Data?], to data: inout Data) {
        appendBigEndian(Int16(fields.count), to: &data)
        for field in fields {
            if let field {
                appendBigEndian(Int32(field.count), to: &data)
                data.append(field)
            } else {
                appendBigEndian(Int32(-1), to: &data)
            }
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

/// Streaming reader for binary COPY data that re-encodes rows as COPY text, formatting each field
/// with ``PostgresBinaryFormatter`` (whose output the server's input functions accept).
struct BinaryCopyToTextConverter {
    private let oids: [UInt32]
    private let formatter = PostgresBinaryFormatter(timeZone: TimeZone(identifier: "UTC")!)
    private var buffer: [UInt8] = []
    private var readHeader = false
    private(set) var finished = false
    private(set) var rowCount = 0

    /// - Parameter oids: Type OID of each target column, in COPY column order.
    init(oids: [UInt32]) {
        self.oids = oids
    }

    mutating func feed(_ bytes: some Sequence<UInt8>, into output: inout [UInt8]) throws {
        buffer.append(contentsOf: bytes)
        var offset = 0
        func readUnsigned(_ size: Int) -> UInt64? {
            guard offset + size <= buffer.count else { return nil }
            var value: UInt64 = 0
            for index in 0..<size { value = value << 8 | UInt64(buffer[offset + index]) }
            offset += size
            return value
        }
        func readInt<T: FixedWidthInteger>(_: T.Type) -> T? {
            readUnsigned(MemoryLayout<T>.size).map { T(truncatingIfNeeded: $0) }
        }

        if !readHeader {
            guard buffer.count >= 19 else { return }
            guard Array(buffer[0..<11]) == BinaryCopyFormat.signature else {
                throw PostgresKitError.notSupported("Binary COPY data does not start with the PGCOPY signature")
            }
            offset = 15
            guard let extensionLength = readInt(UInt32.self), buffer.count >= 19 + Int(extensionLength) else { return }
            offset = 19 + Int(extensionLength)
            readHeader = true
            buffer.removeFirst(offset)
            offset = 0
        }

        while !finished {
            let tupleStart = offset
            guard let fieldCount = readInt(Int16.self) else { break }
            if fieldCount == -1 {
                finished = true
                break
            }
            guard Int(fieldCount) == oids.count else {
                throw PostgresKitError.notSupported("Binary COPY row has \(fieldCount) fields, the target has \(oids.count) columns")
            }
            var fields: [String?] = []
            var complete = true
            for index in 0..<Int(fieldCount) {
                guard let length = readInt(Int32.self) else { complete = false; break }
                if length == -1 { fields.append(nil); continue }
                guard length >= 0, offset + Int(length) <= buffer.count else { complete = false; break }
                let text = buffer.withUnsafeBytes { raw in
                    formatter.string(oid: oids[index], bytes: UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + Int(length))]))
                }
                fields.append(text)
                offset += Int(length)
            }
            guard complete else {
                offset = tupleStart
                break
            }
            output.append(contentsOf: CSVWriter.textLine(fields, delimiter: "\t").utf8)
            rowCount += 1
        }
        buffer.removeFirst(offset)
    }

    func finish() throws {
        guard finished, buffer.isEmpty else {
            throw PostgresKitError.notSupported(readHeader ? "Binary COPY data ended without the trailer" : "Binary COPY data is truncated")
        }
    }
}
