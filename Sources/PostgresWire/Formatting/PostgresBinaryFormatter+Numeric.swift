extension PostgresBinaryFormatter {
    private static let numericPositive: UInt16 = 0x0000
    private static let numericNegative: UInt16 = 0x4000
    private static let numericNaN: UInt16 = 0xC000
    private static let numericPositiveInfinity: UInt16 = 0xD000
    private static let numericNegativeInfinity: UInt16 = 0xF000

    /// Exact `numeric` output (no `Decimal` conversion, so no 38-digit limit).
    ///
    /// Wire format: `ndigits`, `weight`, `sign`, `dscale` (all 16-bit), then `ndigits` base-10000 digits.
    /// `weight` is the position of the first digit relative to the decimal point; `dscale` is the number
    /// of digits shown after the point.
    static func formatNumeric(_ reader: inout PostgresBinaryReader) throws -> String {
        let digitCount = Int(try reader.read(Int16.self))
        let weight = Int(try reader.read(Int16.self))
        let sign = try reader.read(UInt16.self)
        let displayScale = Int(try reader.read(UInt16.self))
        guard digitCount >= 0 else { throw PostgresBinaryFormatError() }
        var digits: [Int] = []
        digits.reserveCapacity(digitCount)
        for _ in 0..<digitCount {
            let digit = Int(try reader.read(Int16.self))
            guard (0..<10_000).contains(digit) else { throw PostgresBinaryFormatError() }
            digits.append(digit)
        }
        try reader.expectEnd()

        switch sign {
        case numericNaN: return "NaN"
        case numericPositiveInfinity: return "Infinity"
        case numericNegativeInfinity: return "-Infinity"
        case numericPositive, numericNegative: break
        default: throw PostgresBinaryFormatError()
        }

        func digit(at index: Int) -> Int {
            index >= 0 && index < digits.count ? digits[index] : 0
        }

        var result = sign == numericNegative ? "-" : ""
        // Integer part: base-10000 digits 0...weight.
        if weight < 0 {
            result += "0"
        } else {
            for index in 0...weight {
                let value = digit(at: index)
                if index == 0 {
                    result += String(value)
                } else {
                    result += pad4(value)
                }
            }
        }
        // Fractional part: continue after the point until dscale decimal digits are written.
        if displayScale > 0 {
            var fraction = ""
            var index = weight + 1
            while fraction.count < displayScale {
                fraction += pad4(digit(at: index))
                index += 1
            }
            result += "." + fraction.prefix(displayScale)
        }
        return result
    }

    private static func pad4(_ value: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: 4 - text.count) + text
    }
}
