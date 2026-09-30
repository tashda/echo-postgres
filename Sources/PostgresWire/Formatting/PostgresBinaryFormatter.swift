import Foundation
import NIOCore

/// Converts binary-format Postgres values into the same text Postgres itself would print.
///
/// PostgresNIO requests every result column in binary format, so this is what turns wire bytes into
/// display strings. It is a plain value type with no per-call allocation beyond the result string,
/// and it only needs the column's type OID — which is why both live rows (``PostgresCell``) and
/// spooled rows (raw bytes + OID) can use the same code and render identically.
///
/// Output follows the server defaults `DateStyle=ISO`, `IntervalStyle=postgres` and
/// `extra_float_digits=1`, with these deliberate differences:
/// - `bool` prints `true` / `false` (not `t` / `f`).
/// - `timestamptz` / `timetz` are shown in ``timeZone`` (the server would use the session `TimeZone`).
/// - `money` prints a plain decimal (the server applies `lc_monetary`).
/// - `reg*` types (`regclass`, …) print the referenced OID; resolving names needs a catalog lookup.
///
/// Types it cannot identify (extension types with dynamic OIDs) are detected structurally when they
/// are arrays, records or hstore, shown as text when they are printable UTF-8, and as `\x…` hex otherwise.
public struct PostgresBinaryFormatter: Sendable {
    /// Time zone used for `timestamptz` values.
    public var timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    /// Format a binary value of type `oid`.
    public func string(oid: UInt32, bytes: UnsafeRawBufferPointer) -> String {
        do {
            return try format(oid: oid, bytes: bytes)
        } catch {
            return Self.hex(bytes)
        }
    }

    /// Format a binary value of type `oid`.
    public func string(oid: UInt32, data: Data) -> String {
        data.withUnsafeBytes { string(oid: oid, bytes: $0) }
    }

    /// Format a binary value of type `oid`.
    public func string(oid: UInt32, buffer: ByteBuffer) -> String {
        buffer.withUnsafeReadableBytes { string(oid: oid, bytes: $0) }
    }

    // MARK: - Dispatch

    func format(oid: UInt32, bytes: UnsafeRawBufferPointer) throws -> String {
        typealias T = PostgresTypeOID
        var reader = PostgresBinaryReader(bytes)
        switch oid {
        case T.bool:
            let value = try reader.read(UInt8.self)
            try reader.expectEnd()
            return value != 0 ? "true" : "false"
        case T.int2:
            let value = try reader.read(Int16.self)
            try reader.expectEnd()
            return String(value)
        case T.int4:
            let value = try reader.read(Int32.self)
            try reader.expectEnd()
            return String(value)
        case T.int8:
            let value = try reader.read(Int64.self)
            try reader.expectEnd()
            return String(value)
        case _ where T.oidLike.contains(oid):
            let value = try reader.read(UInt32.self)
            try reader.expectEnd()
            return String(value)
        case T.xid8:
            let value = try reader.read(UInt64.self)
            try reader.expectEnd()
            return String(value)
        case T.float4:
            let value = try reader.readFloat4()
            try reader.expectEnd()
            return Self.formatFloat(Double(value), description: value.description, exponentThreshold: 6)
        case T.float8:
            let value = try reader.readFloat8()
            try reader.expectEnd()
            return Self.formatFloat(value, description: value.description, exponentThreshold: 15)
        case T.numeric:
            return try Self.formatNumeric(&reader)
        case T.money:
            let cents = try reader.read(Int64.self)
            try reader.expectEnd()
            return Self.formatMoney(cents)
        case _ where T.textLike.contains(oid):
            return String(decoding: bytes, as: UTF8.self)
        case T.jsonb, T.jsonpath:
            let version = try reader.read(UInt8.self)
            guard version == 1 else { throw PostgresBinaryFormatError() }
            return String(decoding: reader.readRest(), as: UTF8.self)
        case T.char:
            return Self.formatChar(bytes)
        case T.bytea:
            return Self.hex(bytes)
        case T.uuid:
            guard bytes.count == 16 else { throw PostgresBinaryFormatError() }
            return Self.formatUUID(bytes)
        case T.void:
            return ""
        case T.pgLSN:
            let value = try reader.read(UInt64.self)
            try reader.expectEnd()
            return String(value >> 32, radix: 16, uppercase: true) + "/" + String(value & 0xFFFF_FFFF, radix: 16, uppercase: true)
        case T.tid:
            let block = try reader.read(UInt32.self)
            let offset = try reader.read(UInt16.self)
            try reader.expectEnd()
            return "(\(block),\(offset))"
        case T.bit, T.varbit:
            return try Self.formatBits(&reader)
        case T.pgSnapshot, T.txidSnapshot:
            return try Self.formatSnapshot(&reader)
        case T.date:
            return try formatDate(&reader)
        case T.time:
            return try formatTime(&reader)
        case T.timetz:
            return try formatTimeTZ(&reader)
        case T.timestamp:
            return try formatTimestamp(&reader, withTimeZone: false)
        case T.timestamptz:
            return try formatTimestamp(&reader, withTimeZone: true)
        case T.interval:
            return try Self.formatInterval(&reader)
        case T.inet, T.cidr:
            return try Self.formatInet(&reader, isCIDR: oid == T.cidr)
        case T.macaddr, T.macaddr8:
            guard bytes.count == (oid == T.macaddr ? 6 : 8) else { throw PostgresBinaryFormatError() }
            return bytes.map { Self.hexByte($0) }.joined(separator: ":")
        case T.point, T.lseg, T.path, T.box, T.polygon, T.line, T.circle:
            return try Self.formatGeometry(oid: oid, &reader)
        case T.tsvector:
            return try Self.formatTSVector(&reader)
        case T.tsquery:
            return try Self.formatTSQuery(&reader)
        case T.int2vector, T.oidvector:
            return try formatVector(&reader)
        case T.record:
            return try formatRecord(&reader)
        case _ where T.arrayTypes.contains(oid):
            return try formatArray(&reader)
        case _ where T.rangeSubtype[oid] != nil:
            return try formatRange(&reader, subtype: T.rangeSubtype[oid]!)
        case _ where T.multirangeRange[oid] != nil:
            return try formatMultirange(&reader, rangeOID: T.multirangeRange[oid]!)
        default:
            return formatUnknown(bytes)
        }
    }

    /// Best effort for types identified only at run time (extensions, enums, domains of arrays, …).
    func formatUnknown(_ bytes: UnsafeRawBufferPointer) -> String {
        if bytes.isEmpty { return "" }
        // Structured binary values start with NUL bytes, which printable text never contains.
        if bytes[0] == 0 {
            var arrayReader = PostgresBinaryReader(bytes)
            if let array = try? formatArray(&arrayReader, strict: true) { return array }
            var hstoreReader = PostgresBinaryReader(bytes)
            if let hstore = try? Self.formatHstore(&hstoreReader) { return hstore }
            var recordReader = PostgresBinaryReader(bytes)
            if let record = try? formatRecord(&recordReader) { return record }
        }
        if let text = Self.printableText(bytes) { return text }
        // ltree / lquery / ltxtquery and similar: a version byte of 1 followed by text.
        if bytes[0] == 1, bytes.count > 1, let text = Self.printableText(UnsafeRawBufferPointer(rebasing: bytes[1...])) {
            return text
        }
        return Self.hex(bytes)
    }

    // MARK: - Scalar helpers

    static func printableText(_ bytes: UnsafeRawBufferPointer) -> String? {
        for byte in bytes where byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
            return nil
        }
        if bytes.contains(0x7F) { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.unicodeScalars.contains("\u{FFFD}") ? nil : text
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    static func hexByte(_ byte: UInt8) -> String {
        String(decoding: [hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]], as: UTF8.self)
    }

    /// `bytea` hex output: `\x0a1b…`.
    static func hex(_ bytes: UnsafeRawBufferPointer) -> String {
        var utf8: [UInt8] = [UInt8(ascii: "\\"), UInt8(ascii: "x")]
        utf8.reserveCapacity(2 + bytes.count * 2)
        for byte in bytes {
            utf8.append(hexDigits[Int(byte >> 4)])
            utf8.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: utf8, as: UTF8.self)
    }

    static func formatUUID(_ bytes: UnsafeRawBufferPointer) -> String {
        var utf8: [UInt8] = []
        utf8.reserveCapacity(36)
        for (index, byte) in bytes.enumerated() {
            if index == 4 || index == 6 || index == 8 || index == 10 { utf8.append(UInt8(ascii: "-")) }
            utf8.append(hexDigits[Int(byte >> 4)])
            utf8.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: utf8, as: UTF8.self)
    }

    /// `"char"`: one byte; high-bit bytes print as `\ooo` like the server.
    static func formatChar(_ bytes: UnsafeRawBufferPointer) -> String {
        guard let byte = bytes.first, byte != 0 else { return "" }
        if byte >= 0x80 {
            return "\\" + String(byte >> 6) + String((byte >> 3) & 7) + String(byte & 7)
        }
        return String(UnicodeScalar(byte))
    }

    static func formatMoney(_ cents: Int64) -> String {
        let magnitude = cents.magnitude
        let fraction = magnitude % 100
        return (cents < 0 ? "-" : "") + String(magnitude / 100) + "." + (fraction < 10 ? "0" : "") + String(fraction)
    }

    static func formatBits(_ reader: inout PostgresBinaryReader) throws -> String {
        let length = Int(try reader.read(Int32.self))
        let data = reader.readRest()
        guard length >= 0, data.count == (length + 7) / 8 else { throw PostgresBinaryFormatError() }
        var utf8: [UInt8] = []
        utf8.reserveCapacity(length)
        for index in 0..<length {
            let bit = (data[index / 8] >> (7 - UInt8(index % 8))) & 1
            utf8.append(bit == 1 ? UInt8(ascii: "1") : UInt8(ascii: "0"))
        }
        return String(decoding: utf8, as: UTF8.self)
    }

    static func formatSnapshot(_ reader: inout PostgresBinaryReader) throws -> String {
        let count = Int(try reader.read(Int32.self))
        let xmin = try reader.read(UInt64.self)
        let xmax = try reader.read(UInt64.self)
        guard count >= 0 else { throw PostgresBinaryFormatError() }
        var inProgress: [String] = []
        for _ in 0..<count { inProgress.append(String(try reader.read(UInt64.self))) }
        try reader.expectEnd()
        return "\(xmin):\(xmax):" + inProgress.joined(separator: ",")
    }

    /// Shortest round-trip digits (from Swift's `description`) laid out the way Postgres prints floats:
    /// positional below 10^threshold, otherwise `d.ddde+XX`.
    static func formatFloat(_ value: Double, description: String, exponentThreshold: Int) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return value.sign == .minus ? "-0" : "0" }

        // Split the description into significant digits and a decimal exponent.
        var mantissa = Substring(description)
        var exponent = 0
        let negative = mantissa.first == "-"
        if negative { mantissa = mantissa.dropFirst() }
        if let e = mantissa.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(mantissa[mantissa.index(after: e)...]) ?? 0
            mantissa = mantissa[..<e]
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let integerPart = parts[0]
        let fractionPart = parts.count > 1 ? parts[1] : ""
        var digits = Array(integerPart + fractionPart)
        // The decimal point sits after `pointIndex` digits of `digits`.
        var pointIndex = integerPart.count + exponent
        while digits.first == "0" { digits.removeFirst(); pointIndex -= 1 }
        while digits.last == "0" { digits.removeLast() }
        guard !digits.isEmpty else { return "0" }

        let decimalExponent = pointIndex - 1
        var result = negative ? "-" : ""
        if decimalExponent < -4 || decimalExponent >= exponentThreshold {
            result.append(digits[0])
            if digits.count > 1 {
                result.append(".")
                result.append(contentsOf: digits[1...])
            }
            let magnitude = abs(decimalExponent)
            result += (decimalExponent < 0 ? "e-" : "e+") + (magnitude < 10 ? "0" : "") + String(magnitude)
        } else if pointIndex <= 0 {
            result += "0." + String(repeating: "0", count: -pointIndex) + String(digits)
        } else if pointIndex >= digits.count {
            result += String(digits) + String(repeating: "0", count: pointIndex - digits.count)
        } else {
            result += String(digits[..<pointIndex]) + "." + String(digits[pointIndex...])
        }
        return result
    }
}
