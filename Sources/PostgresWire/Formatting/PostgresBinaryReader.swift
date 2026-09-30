import Foundation

/// Thrown when a binary value is shorter or longer than its format says.
struct PostgresBinaryFormatError: Error {}

/// Big-endian cursor over the bytes of one binary-format Postgres value.
struct PostgresBinaryReader {
    let bytes: UnsafeRawBufferPointer
    private(set) var offset = 0

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw PostgresBinaryFormatError() }
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
        offset += size
        return T(bigEndian: value)
    }

    mutating func readFloat4() throws -> Float {
        Float(bitPattern: try read(UInt32.self))
    }

    mutating func readFloat8() throws -> Double {
        Double(bitPattern: try read(UInt64.self))
    }

    mutating func readSlice(_ count: Int) throws -> UnsafeRawBufferPointer {
        guard count >= 0, remaining >= count else { throw PostgresBinaryFormatError() }
        let slice = UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + count)])
        offset += count
        return slice
    }

    mutating func readRest() -> UnsafeRawBufferPointer {
        let slice = UnsafeRawBufferPointer(rebasing: bytes[offset...])
        offset = bytes.count
        return slice
    }

    /// A NUL-terminated UTF-8 string.
    mutating func readCString() throws -> String {
        guard let end = bytes[offset...].firstIndex(of: 0) else { throw PostgresBinaryFormatError() }
        let slice = UnsafeRawBufferPointer(rebasing: bytes[offset..<end])
        offset = end + 1
        return String(decoding: slice, as: UTF8.self)
    }

    /// A length-prefixed value (`int32` length, `-1` for NULL).
    mutating func readLengthPrefixed() throws -> UnsafeRawBufferPointer? {
        let length = try read(Int32.self)
        if length == -1 { return nil }
        return try readSlice(Int(length))
    }

    func expectEnd() throws {
        guard isAtEnd else { throw PostgresBinaryFormatError() }
    }
}
