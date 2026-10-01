import Foundation

/// ISO date and time text as the server prints it with `DateStyle=ISO`
/// (`2026-10-01`, `2026-10-01 12:34:56.789`, `2026-10-01 12:34:56+02`, `… 12:34:56.5+05:30`).
enum PostgresDateText {
    /// A point in time; `timestamp` without zone is read as UTC. Nil for `infinity` and BC dates.
    static func parse(_ text: String) -> Date? {
        var scanner = DigitScanner(Array(text.utf8))
        guard let year = scanner.number(digits: 4), scanner.skip(UInt8(ascii: "-")),
              let month = scanner.number(digits: 2), scanner.skip(UInt8(ascii: "-")),
              let day = scanner.number(digits: 2) else { return nil }
        var components = DateComponents(calendar: calendar, timeZone: utc, year: year, month: month, day: day)
        var offsetSeconds = 0
        if scanner.skip(UInt8(ascii: " ")) || scanner.skip(UInt8(ascii: "T")) {
            guard let hour = scanner.number(digits: 2), scanner.skip(UInt8(ascii: ":")),
                  let minute = scanner.number(digits: 2), scanner.skip(UInt8(ascii: ":")),
                  let second = scanner.number(digits: 2) else { return nil }
            components.hour = hour
            components.minute = minute
            components.second = second
            if scanner.skip(UInt8(ascii: ".")) {
                let (fraction, count) = scanner.fraction()
                components.nanosecond = fraction * Int(pow(10.0, Double(9 - min(count, 9))))
            }
            if let sign = scanner.sign() {
                guard let hours = scanner.number(digits: 2) else { return nil }
                var minutes = 0, seconds = 0
                if scanner.skip(UInt8(ascii: ":")) { minutes = scanner.number(digits: 2) ?? 0 }
                if scanner.skip(UInt8(ascii: ":")) { seconds = scanner.number(digits: 2) ?? 0 }
                offsetSeconds = sign * (hours * 3600 + minutes * 60 + seconds)
            }
        }
        guard scanner.isAtEnd, let date = calendar.date(from: components) else { return nil }
        return date.addingTimeInterval(TimeInterval(-offsetSeconds))
    }

    /// `timestamptz` text in UTC with microseconds, for statement parameters.
    static func format(_ date: Date) -> String {
        let seconds = floor(date.timeIntervalSince1970)
        let micros = Int((date.timeIntervalSince1970 - seconds) * 1_000_000 + 0.5)
        let parts = calendar.dateComponents(in: utc, from: Date(timeIntervalSince1970: seconds))
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%06d+00",
                      parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, min(micros, 999_999))
    }

    private static let utc = TimeZone(identifier: "UTC") ?? .gmt
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()

    private struct DigitScanner {
        let bytes: [UInt8]
        var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var isAtEnd: Bool { index == bytes.count }

        mutating func skip(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        /// At least `digits` digits (years can have more).
        mutating func number(digits: Int) -> Int? {
            var value = 0, count = 0
            while index < bytes.count, (48...57).contains(bytes[index]) {
                value = value * 10 + Int(bytes[index] - 48)
                index += 1
                count += 1
            }
            return count >= digits ? value : nil
        }

        mutating func fraction() -> (Int, Int) {
            var value = 0, count = 0
            while index < bytes.count, (48...57).contains(bytes[index]) {
                if count < 9 { value = value * 10 + Int(bytes[index] - 48) }
                index += 1
                count += 1
            }
            return (value, min(count, 9))
        }

        mutating func sign() -> Int? {
            if skip(UInt8(ascii: "+")) { return 1 }
            if skip(UInt8(ascii: "-")) { return -1 }
            return nil
        }
    }
}

/// `bytea` text output: hex (`\x0a0b`) or the older escape format.
enum PostgresByteaText {
    static func parse(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        if bytes.count >= 2, bytes[0] == UInt8(ascii: "\\"), bytes[1] == UInt8(ascii: "x") {
            guard bytes.count % 2 == 0 else { return nil }
            var data = Data(capacity: (bytes.count - 2) / 2)
            var index = 2
            while index < bytes.count {
                guard let high = hex(bytes[index]), let low = hex(bytes[index + 1]) else { return nil }
                data.append(high << 4 | low)
                index += 2
            }
            return data
        }
        var data = Data(capacity: bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\") {
                if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\\") {
                    data.append(UInt8(ascii: "\\")); index += 2; continue
                }
                guard index + 3 < bytes.count else { return nil }
                let octal = bytes[(index + 1)...(index + 3)].reduce(0) { $0 * 8 + Int($1) - 48 }
                guard (0...255).contains(octal) else { return nil }
                data.append(UInt8(octal)); index += 4
            } else {
                data.append(bytes[index]); index += 1
            }
        }
        return data
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 97...102: byte - 87
        case 65...70: byte - 55
        default: nil
        }
    }
}
