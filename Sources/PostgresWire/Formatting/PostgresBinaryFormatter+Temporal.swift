import Foundation

extension PostgresBinaryFormatter {
    /// Julian day number of 2000-01-01, the Postgres epoch.
    private static let postgresEpochJulianDay = 2_451_545
    private static let microsecondsPerSecond: Int64 = 1_000_000
    private static let microsecondsPerMinute: Int64 = 60 * microsecondsPerSecond
    private static let microsecondsPerHour: Int64 = 60 * microsecondsPerMinute
    private static let microsecondsPerDay: Int64 = 24 * microsecondsPerHour
    /// Seconds between 1970-01-01 and 2000-01-01.
    private static let postgresEpochUnixSeconds: Int64 = 946_684_800

    // MARK: - Values

    func formatDate(_ reader: inout PostgresBinaryReader) throws -> String {
        let days = try reader.read(Int32.self)
        try reader.expectEnd()
        if days == .max { return "infinity" }
        if days == .min { return "-infinity" }
        let (year, month, day) = Self.julianDayToDate(Int(days) + Self.postgresEpochJulianDay)
        return Self.dateString(year: year, month: month, day: day) + (year <= 0 ? " BC" : "")
    }

    func formatTime(_ reader: inout PostgresBinaryReader) throws -> String {
        let microseconds = try reader.read(Int64.self)
        try reader.expectEnd()
        return Self.timeString(microseconds)
    }

    func formatTimeTZ(_ reader: inout PostgresBinaryReader) throws -> String {
        let microseconds = try reader.read(Int64.self)
        // The zone is stored in seconds *west* of UTC.
        let secondsWest = try reader.read(Int32.self)
        try reader.expectEnd()
        return Self.timeString(microseconds) + Self.offsetString(secondsEast: -Int(secondsWest))
    }

    func formatTimestamp(_ reader: inout PostgresBinaryReader, withTimeZone: Bool) throws -> String {
        var microseconds = try reader.read(Int64.self)
        try reader.expectEnd()
        if microseconds == .max { return "infinity" }
        if microseconds == .min { return "-infinity" }

        var offsetSuffix = ""
        if withTimeZone {
            let unixSeconds = Double(microseconds) / 1_000_000 + Double(Self.postgresEpochUnixSeconds)
            let offset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: unixSeconds))
            microseconds += Int64(offset) * Self.microsecondsPerSecond
            offsetSuffix = Self.offsetString(secondsEast: offset)
        }

        var days = microseconds / Self.microsecondsPerDay
        var timeOfDay = microseconds % Self.microsecondsPerDay
        if timeOfDay < 0 {
            timeOfDay += Self.microsecondsPerDay
            days -= 1
        }
        let (year, month, day) = Self.julianDayToDate(Int(days) + Self.postgresEpochJulianDay)
        return Self.dateString(year: year, month: month, day: day)
            + " " + Self.timeString(timeOfDay)
            + offsetSuffix
            + (year <= 0 ? " BC" : "")
    }

    /// `IntervalStyle = postgres`, e.g. `1 year 2 mons -3 days +04:05:06.5`.
    static func formatInterval(_ reader: inout PostgresBinaryReader) throws -> String {
        var time = try reader.read(Int64.self)
        let days = Int64(try reader.read(Int32.self))
        let months = Int64(try reader.read(Int32.self))
        try reader.expectEnd()

        let years = months / 12
        let remainingMonths = months % 12
        let hours = time / microsecondsPerHour
        time -= hours * microsecondsPerHour
        let minutes = time / microsecondsPerMinute
        time -= minutes * microsecondsPerMinute
        let seconds = time / microsecondsPerSecond
        let fraction = time - seconds * microsecondsPerSecond

        var result = ""
        var isZero = true
        var isBefore = false
        func addPart(_ value: Int64, _ unit: String) {
            guard value != 0 else { return }
            result += (isZero ? "" : " ") + (isBefore && value > 0 ? "+" : "") + "\(value) \(unit)" + (value != 1 ? "s" : "")
            isBefore = value < 0
            isZero = false
        }
        addPart(years, "year")
        addPart(remainingMonths, "mon")
        addPart(days, "day")
        if isZero || hours != 0 || minutes != 0 || seconds != 0 || fraction != 0 {
            let minus = hours < 0 || minutes < 0 || seconds < 0 || fraction < 0
            result += (isZero ? "" : " ") + (minus ? "-" : (isBefore ? "+" : ""))
            result += pad2(hours.magnitude) + ":" + pad2(minutes.magnitude) + ":" + pad2(seconds.magnitude)
            result += fractionString(fraction.magnitude)
        }
        return result
    }

    // MARK: - Helpers

    /// Postgres `j2date`: proleptic Gregorian calendar for every date (Foundation switches to
    /// Julian before 1582, which shifts old and BC dates).
    static func julianDayToDate(_ julianDay: Int) -> (year: Int, month: Int, day: Int) {
        var julian = UInt32(truncatingIfNeeded: julianDay) &+ 32044
        var quad = julian / 146_097
        let extra = (julian &- quad &* 146_097) &* 4 &+ 3
        julian = julian &+ 60 &+ quad &* 3 &+ extra / 146_097
        quad = julian / 1461
        julian = julian &- quad &* 1461
        var year = julian &* 4 / 1461
        julian = (year != 0 ? (julian &+ 305) % 365 : (julian &+ 306) % 366) &+ 123
        year = year &+ quad &* 4
        quad = julian &* 2141 / 65536
        let day = julian &- 7834 &* quad / 256
        let month = (quad &+ 10) % 12 &+ 1
        return (Int(Int32(bitPattern: year)) - 4800, Int(month), Int(day))
    }

    /// `YYYY-MM-DD`; years ≤ 0 are shown as `1 - year` (the caller appends ` BC`).
    static func dateString(year: Int, month: Int, day: Int) -> String {
        let displayYear = year > 0 ? year : 1 - year
        let yearText = String(displayYear)
        return String(repeating: "0", count: max(0, 4 - yearText.count)) + yearText + "-" + pad2(UInt64(month)) + "-" + pad2(UInt64(day))
    }

    static func timeString(_ microseconds: Int64) -> String {
        let magnitude = microseconds.magnitude
        let totalSeconds = magnitude / UInt64(microsecondsPerSecond)
        let fraction = magnitude % UInt64(microsecondsPerSecond)
        return pad2(totalSeconds / 3600) + ":" + pad2(totalSeconds / 60 % 60) + ":" + pad2(totalSeconds % 60) + fractionString(fraction)
    }

    /// `+HH`, `+HH:MM` or `+HH:MM:SS` like the server's ISO output.
    static func offsetString(secondsEast: Int) -> String {
        let magnitude = UInt64(abs(secondsEast))
        var text = (secondsEast < 0 ? "-" : "+") + pad2(magnitude / 3600)
        let minutes = magnitude / 60 % 60
        let seconds = magnitude % 60
        if minutes != 0 || seconds != 0 { text += ":" + pad2(minutes) }
        if seconds != 0 { text += ":" + pad2(seconds) }
        return text
    }

    /// `.ffffff` with trailing zeros removed, or empty.
    static func fractionString(_ microseconds: UInt64) -> String {
        guard microseconds != 0 else { return "" }
        var text = String(microseconds)
        text = String(repeating: "0", count: 6 - text.count) + text
        while text.last == "0" { text.removeLast() }
        return "." + text
    }

    static func pad2(_ value: UInt64) -> String {
        value < 10 ? "0" + String(value) : String(value)
    }
}
