extension PostgresBinaryFormatter {
    private static let maxArrayDimensions = 6

    // MARK: - Arrays

    /// `array_send` format: dimensions, has-nulls flag, element OID, (size, lower bound) per dimension,
    /// then length-prefixed elements. `strict` is used when guessing whether unknown bytes are an array.
    func formatArray(_ reader: inout PostgresBinaryReader, strict: Bool = false) throws -> String {
        let dimensionCount = Int(try reader.read(Int32.self))
        let hasNulls = try reader.read(Int32.self)
        let elementOID = try reader.read(UInt32.self)
        guard (0...Self.maxArrayDimensions).contains(dimensionCount), hasNulls == 0 || hasNulls == 1 else {
            throw PostgresBinaryFormatError()
        }
        if strict, dimensionCount == 0 || elementOID == 0 { throw PostgresBinaryFormatError() }
        if dimensionCount == 0 {
            try reader.expectEnd()
            return "{}"
        }

        var sizes: [Int] = []
        var lowerBounds: [Int] = []
        for _ in 0..<dimensionCount {
            let size = Int(try reader.read(Int32.self))
            guard size >= 0 else { throw PostgresBinaryFormatError() }
            sizes.append(size)
            lowerBounds.append(Int(try reader.read(Int32.self)))
        }
        let total = sizes.reduce(1, *)
        guard total <= reader.remaining / 4 else { throw PostgresBinaryFormatError() }

        var elements: [String?] = []
        elements.reserveCapacity(total)
        for _ in 0..<total {
            if let bytes = try reader.readLengthPrefixed() {
                elements.append(try format(oid: elementOID, bytes: bytes))
            } else {
                guard hasNulls == 1 else { throw PostgresBinaryFormatError() }
                elements.append(nil)
            }
        }
        try reader.expectEnd()

        let delimiter: Character = elementOID == PostgresTypeOID.box ? ";" : ","
        var result = ""
        if lowerBounds.contains(where: { $0 != 1 }) {
            for (size, lower) in zip(sizes, lowerBounds) {
                result += "[\(lower):\(lower + size - 1)]"
            }
            result += "="
        }
        var position = 0
        func emit(dimension: Int) {
            result.append("{")
            for index in 0..<sizes[dimension] {
                if index > 0 { result.append(delimiter) }
                if dimension == sizes.count - 1 {
                    result += Self.arrayElement(elements[position], delimiter: delimiter)
                    position += 1
                } else {
                    emit(dimension: dimension + 1)
                }
            }
            result.append("}")
        }
        emit(dimension: 0)
        return result
    }

    /// `int2vector` / `oidvector`: array wire format, printed space-separated without braces.
    func formatVector(_ reader: inout PostgresBinaryReader) throws -> String {
        let dimensionCount = Int(try reader.read(Int32.self))
        _ = try reader.read(Int32.self)
        let elementOID = try reader.read(UInt32.self)
        guard dimensionCount <= 1 else { throw PostgresBinaryFormatError() }
        var count = 0
        if dimensionCount == 1 {
            count = Int(try reader.read(Int32.self))
            _ = try reader.read(Int32.self)
        }
        var values: [String] = []
        for _ in 0..<count {
            guard let bytes = try reader.readLengthPrefixed() else { throw PostgresBinaryFormatError() }
            values.append(try format(oid: elementOID, bytes: bytes))
        }
        try reader.expectEnd()
        return values.joined(separator: " ")
    }

    static func arrayElement(_ value: String?, delimiter: Character) -> String {
        guard let value else { return "NULL" }
        let needsQuotes = value.isEmpty
            || value.caseInsensitiveCompare("NULL") == .orderedSame
            || value.contains(where: { $0 == "\"" || $0 == "\\" || $0 == "{" || $0 == "}" || $0 == delimiter || isSpace($0) })
        guard needsQuotes else { return value }
        var quoted = "\""
        for character in value {
            if character == "\"" || character == "\\" { quoted.append("\\") }
            quoted.append(character)
        }
        return quoted + "\""
    }

    static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r"
            || character == "\u{0B}" || character == "\u{0C}"
    }

    // MARK: - Ranges

    private static let rangeEmpty: UInt8 = 0x01
    private static let rangeLowerInclusive: UInt8 = 0x02
    private static let rangeUpperInclusive: UInt8 = 0x04
    private static let rangeLowerInfinite: UInt8 = 0x08
    private static let rangeUpperInfinite: UInt8 = 0x10
    private static let rangeLowerNull: UInt8 = 0x20
    private static let rangeUpperNull: UInt8 = 0x40

    func formatRange(_ reader: inout PostgresBinaryReader, subtype: UInt32) throws -> String {
        let flags = try reader.read(UInt8.self)
        if flags & Self.rangeEmpty != 0 {
            try reader.expectEnd()
            return "empty"
        }
        func bound(absent: UInt8) throws -> String {
            guard flags & absent == 0 else { return "" }
            guard let bytes = try reader.readLengthPrefixed() else { throw PostgresBinaryFormatError() }
            return Self.rangeBound(try format(oid: subtype, bytes: bytes))
        }
        let lower = try bound(absent: Self.rangeLowerInfinite | Self.rangeLowerNull)
        let upper = try bound(absent: Self.rangeUpperInfinite | Self.rangeUpperNull)
        try reader.expectEnd()
        return (flags & Self.rangeLowerInclusive != 0 ? "[" : "(") + lower + "," + upper
            + (flags & Self.rangeUpperInclusive != 0 ? "]" : ")")
    }

    func formatMultirange(_ reader: inout PostgresBinaryReader, rangeOID: UInt32) throws -> String {
        guard let subtype = PostgresTypeOID.rangeSubtype[rangeOID] else { throw PostgresBinaryFormatError() }
        let count = Int(try reader.read(Int32.self))
        guard count >= 0 else { throw PostgresBinaryFormatError() }
        var ranges: [String] = []
        for _ in 0..<count {
            guard let bytes = try reader.readLengthPrefixed() else { throw PostgresBinaryFormatError() }
            var rangeReader = PostgresBinaryReader(bytes)
            ranges.append(try formatRange(&rangeReader, subtype: subtype))
        }
        try reader.expectEnd()
        return "{" + ranges.joined(separator: ",") + "}"
    }

    static func rangeBound(_ value: String) -> String {
        let needsQuotes = value.isEmpty || value.contains(where: {
            $0 == "\"" || $0 == "\\" || $0 == "(" || $0 == ")" || $0 == "[" || $0 == "]" || $0 == "," || isSpace($0)
        })
        guard needsQuotes else { return value }
        var quoted = "\""
        for character in value {
            if character == "\"" || character == "\\" { quoted.append(character) }
            quoted.append(character)
        }
        return quoted + "\""
    }

    // MARK: - Records

    /// `record_send`: field count, then (OID, length-prefixed value) per field.
    func formatRecord(_ reader: inout PostgresBinaryReader) throws -> String {
        let fieldCount = Int(try reader.read(Int32.self))
        guard fieldCount >= 0, fieldCount <= reader.remaining / 8 else { throw PostgresBinaryFormatError() }
        var fields: [String] = []
        for _ in 0..<fieldCount {
            let oid = try reader.read(UInt32.self)
            if let bytes = try reader.readLengthPrefixed() {
                fields.append(Self.recordField(try format(oid: oid, bytes: bytes)))
            } else {
                fields.append("")
            }
        }
        try reader.expectEnd()
        return "(" + fields.joined(separator: ",") + ")"
    }

    static func recordField(_ value: String) -> String {
        let needsQuotes = value.isEmpty || value.contains(where: {
            $0 == "\"" || $0 == "\\" || $0 == "(" || $0 == ")" || $0 == "," || isSpace($0)
        })
        guard needsQuotes else { return value }
        var quoted = "\""
        for character in value {
            if character == "\"" || character == "\\" { quoted.append(character) }
            quoted.append(character)
        }
        return quoted + "\""
    }

    // MARK: - hstore

    /// hstore (dynamic OID): pair count, then length-prefixed key and value (value may be NULL).
    static func formatHstore(_ reader: inout PostgresBinaryReader) throws -> String {
        let count = Int(try reader.read(Int32.self))
        guard count >= 0, count <= reader.remaining / 8 else { throw PostgresBinaryFormatError() }
        func quoted(_ bytes: UnsafeRawBufferPointer) throws -> String {
            guard let text = printableText(bytes) ?? (bytes.isEmpty ? "" : nil) else { throw PostgresBinaryFormatError() }
            var result = "\""
            for character in text {
                if character == "\"" || character == "\\" { result.append("\\") }
                result.append(character)
            }
            return result + "\""
        }
        var pairs: [String] = []
        for _ in 0..<count {
            guard let key = try reader.readLengthPrefixed() else { throw PostgresBinaryFormatError() }
            let value = try reader.readLengthPrefixed()
            pairs.append(try quoted(key) + "=>" + (try value.map(quoted) ?? "NULL"))
        }
        try reader.expectEnd()
        return pairs.joined(separator: ", ")
    }
}
