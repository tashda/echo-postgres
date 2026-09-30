extension PostgresBinaryFormatter {
    private static let familyIPv4: UInt8 = 2
    private static let familyIPv6: UInt8 = 3

    /// `inet` / `cidr`: family, prefix bits, is-cidr flag, address length, address bytes.
    static func formatInet(_ reader: inout PostgresBinaryReader, isCIDR: Bool) throws -> String {
        let family = try reader.read(UInt8.self)
        let bits = Int(try reader.read(UInt8.self))
        _ = try reader.read(UInt8.self)
        let length = Int(try reader.read(UInt8.self))
        let address = try reader.readSlice(length)
        try reader.expectEnd()

        let text: String
        let maxBits: Int
        switch family {
        case familyIPv4 where length == 4:
            text = address.map(String.init).joined(separator: ".")
            maxBits = 32
        case familyIPv6 where length == 16:
            text = ipv6String(address)
            maxBits = 128
        default:
            throw PostgresBinaryFormatError()
        }
        return (isCIDR || bits != maxBits) ? "\(text)/\(bits)" : text
    }

    /// RFC 5952 text form (the longest run of two or more zero groups becomes `::`), with the
    /// dotted-quad tail for IPv4-mapped and IPv4-compatible addresses, as Postgres prints them.
    static func ipv6String(_ address: UnsafeRawBufferPointer) -> String {
        var words: [UInt16] = []
        for index in stride(from: 0, to: 16, by: 2) {
            words.append(UInt16(address[index]) << 8 | UInt16(address[index + 1]))
        }

        var bestStart = -1, bestLength = 0
        var currentStart = -1, currentLength = 0
        for (index, word) in words.enumerated() {
            if word == 0 {
                if currentStart == -1 { currentStart = index; currentLength = 1 } else { currentLength += 1 }
                if currentLength > bestLength { bestStart = currentStart; bestLength = currentLength }
            } else {
                currentStart = -1
                currentLength = 0
            }
        }
        if bestLength < 2 { bestStart = -1 }

        var text = ""
        var index = 0
        while index < 8 {
            if index == bestStart {
                text += "::"
                index += bestLength
                continue
            }
            if index > 0, !text.hasSuffix(":") { text += ":" }
            // Embedded IPv4: ::a.b.c.d or ::ffff:a.b.c.d
            if index == 6, bestStart == 0, bestLength == 6 || (bestLength == 5 && words[5] == 0xFFFF) {
                text += (12..<16).map { String(address[$0]) }.joined(separator: ".")
                return text
            }
            text += String(words[index], radix: 16)
            index += 1
        }
        return text
    }
}
