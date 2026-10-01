#if canImport(CLibpq)
internal import CLibpq
#else
internal import CLibpqSystem
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// One `$n` parameter of a statement, as libpq sends it: text (the server parses it as the
/// parameter's type), binary bytes (`bytea`), or NULL. `typeOID` 0 lets the server infer the type.
public struct PGParameter: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case null
        case text(String)
        case binary(Data)
    }

    public var value: Value
    public var typeOID: UInt32

    public init(_ value: Value, typeOID: UInt32 = 0) {
        self.value = value
        self.typeOID = typeOID
    }

    public static let null = PGParameter(.null)
    public static func text(_ text: String, typeOID: UInt32 = 0) -> PGParameter { PGParameter(.text(text), typeOID: typeOID) }
    /// Bytes sent in binary format; `bytea` (OID 17) unless said otherwise.
    public static func binary(_ data: Data, typeOID: UInt32 = 17) -> PGParameter { PGParameter(.binary(data), typeOID: typeOID) }
}

extension Array where Element == PGParameter {
    /// The C arrays `PQsendQueryParams` takes, valid inside `body`.
    func withCArrays<R>(
        _ body: (UnsafePointer<Oid>, UnsafePointer<UnsafePointer<CChar>?>, UnsafePointer<Int32>, UnsafePointer<Int32>) throws -> R
    ) rethrows -> R {
        let count = Swift.max(1, self.count)
        let types = UnsafeMutablePointer<Oid>.allocate(capacity: count)
        let values = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: count)
        let lengths = UnsafeMutablePointer<Int32>.allocate(capacity: count)
        let formats = UnsafeMutablePointer<Int32>.allocate(capacity: count)
        var owned: [UnsafeMutableRawPointer] = []
        defer {
            owned.forEach { $0.deallocate() }
            types.deallocate(); values.deallocate(); lengths.deallocate(); formats.deallocate()
        }
        for (index, parameter) in enumerated() {
            types[index] = Oid(parameter.typeOID)
            switch parameter.value {
            case .null:
                values[index] = nil
                lengths[index] = 0
                formats[index] = 0
            case .text(let text):
                let utf8 = text.utf8CString
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: utf8.count, alignment: 1)
                utf8.withUnsafeBytes { source in
                    if let base = source.baseAddress { buffer.copyMemory(from: base, byteCount: utf8.count) }
                }
                owned.append(buffer)
                values[index] = UnsafePointer(buffer.assumingMemoryBound(to: CChar.self))
                lengths[index] = 0
                formats[index] = 0
            case .binary(let data):
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: Swift.max(1, data.count), alignment: 1)
                data.withUnsafeBytes { source in
                    if let base = source.baseAddress { buffer.copyMemory(from: base, byteCount: data.count) }
                }
                owned.append(buffer)
                values[index] = UnsafePointer(buffer.assumingMemoryBound(to: CChar.self))
                lengths[index] = Int32(data.count)
                formats[index] = 1
            }
        }
        return try body(types, values, lengths, formats)
    }
}
