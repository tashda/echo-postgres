import Foundation
import PostgresWire

extension ResultSpoolHandle {
    func decodeRowData(_ data: Data) -> [String?] {
        // PROTOTYPE (E2): Postgres columns carry "TYPE(OID)"; format their binary cells with the driver.
        let oids = metadata.columns.map { PostgresRowExtractor.oid(fromDataType: $0.dataType) }
        if metadata.rowEncoding == "binary_v1", oids.contains(where: { $0 != nil }) {
            return Self.decodePostgresRow(data, oids: oids)
        }
        if metadata.rowEncoding == "binary_v1" {
            let binaryRow = ResultBinaryRow(data: data)
            let columnCount = max(metadata.columns.count, 1)
            var values = ResultBinaryRowCodec.decode(binaryRow, columnCount: columnCount)
            normalizeValues(&values)
            return values
        } else {
            return decodeLegacyJSONRow(from: data)
        }
    }

    func decodeLegacyJSONRow(from data: Data) -> [String?] {
        let decoder = makeJSONDecoder()
        if let row = try? decoder.decode([String?].self, from: data) {
            return row
        }
        return []
    }

    nonisolated func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func normalizeValues(_ values: inout [String?]) {
        guard !values.isEmpty else { return }
        let columns = metadata.columns
        for index in 0..<min(values.count, columns.count) {
            guard let raw = values[index] else { continue }
            let type = columns[index].dataType.lowercased()
            if type.contains("bool") {
                let lower = raw.lowercased()
                if lower == "t" || lower == "true" {
                    values[index] = "true"
                } else if lower == "f" || lower == "false" {
                    values[index] = "false"
                }
            }
        }
    }

    nonisolated static func decodePostgresRow(_ data: Data, oids: [UInt32?]) -> [String?] {
        let formatter = PostgresCellFormatter()
        var values: [String?] = []
        values.reserveCapacity(oids.count)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count, values.count < oids.count {
                let flag = bytes[offset]
                offset += 1
                if flag == 0 { values.append(nil); continue }
                guard offset + 4 <= bytes.count else { break }
                let length = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                offset += 4
                guard offset + length <= bytes.count else { break }
                let cell = UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + length)])
                offset += length
                if let oid = oids[values.count] {
                    values.append(formatter.stringValue(oid: oid, bytes: cell))
                } else {
                    values.append(String(decoding: cell, as: UTF8.self))
                }
            }
        }
        while values.count < oids.count { values.append(nil) }
        return values
    }
}
