import Foundation

/// Turns a value's text (as the server sent it) into the text Echo shows (decision D11).
///
/// Values arrive as the server prints them (`DateStyle=ISO`, `IntervalStyle=postgres`) and are shown
/// that way, with two exceptions kept from before the switch to libpq:
/// - `bool` (and `bool[]`) shows `true` / `false` (the server prints `t` / `f`);
/// - `timestamptz` shows in ``timeZone`` (the Mac's), not the session's.
///
/// The same function serves live cells and spooled bytes, so both look the same.
public struct PostgresCellFormatter: Sendable {
    /// Time zone for `timestamptz` values.
    public let timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    /// A cell's display text; nil for NULL.
    public func stringValue(for cell: PostgresCell) -> String? {
        cell.withBytes { bytes in bytes.map { stringValue(oid: cell.dataType, bytes: $0) } }
    }

    /// Display text of spooled bytes (the server's text); nil for NULL.
    public func stringValue(oid: UInt32, data: Data?) -> String? {
        guard let data else { return nil }
        return data.withUnsafeBytes { stringValue(oid: oid, bytes: $0) }
    }

    /// Display text of the server's text bytes.
    public func stringValue(oid: UInt32, bytes: UnsafeRawBufferPointer) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        switch oid {
        case 16: return text == "t" ? "true" : text == "f" ? "false" : text
        case 1000: return Self.booleanArray(text)
        case 1184: return PostgresTimestampDisplay.inTimeZone(text, timeZone) ?? text
        default: return text
        }
    }

    /// `{t,f,NULL}` → `{true,false,NULL}` (also nested), so booleans read the same inside arrays.
    static func booleanArray(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count + 8)
        var token = ""
        func flush() {
            output += token == "t" ? "true" : token == "f" ? "false" : token
            token = ""
        }
        for character in text {
            if character == "{" || character == "}" || character == "," {
                flush()
                output.append(character)
            } else {
                token.append(character)
            }
        }
        flush()
        return output
    }

    /// Display text without the time-zone conversion (cheapest; used when rich formatting is off).
    public static func cheapStringValue(for cell: PostgresCell) -> String? {
        guard let text = cell.string else { return nil }
        if cell.dataType == 16 { return text == "t" ? "true" : text == "f" ? "false" : text }
        return text
    }
}

/// `timestamptz` text moved into another time zone, in the server's ISO shape
/// (`2026-10-01 14:05:06.5+02`).
enum PostgresTimestampDisplay {
    static func inTimeZone(_ text: String, _ zone: TimeZone) -> String? {
        guard text != "infinity", text != "-infinity", !text.hasSuffix(" BC"), let date = PostgresDateText.parse(text) else { return nil }
        let offset = zone.secondsFromGMT(for: date)
        let shifted = date.addingTimeInterval(TimeInterval(offset))
        let seconds = floor(shifted.timeIntervalSince1970)
        let micros = Int(((shifted.timeIntervalSince1970 - seconds) * 1_000_000).rounded())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: seconds))
        let year = String(parts.year ?? 1970)
        return String(repeating: "0", count: max(0, 4 - year.count)) + year
            + "-" + pad2(parts.month ?? 1) + "-" + pad2(parts.day ?? 1)
            + " " + pad2(parts.hour ?? 0) + ":" + pad2(parts.minute ?? 0) + ":" + pad2(parts.second ?? 0)
            + fraction(min(micros, 999_999)) + offsetText(offset)
    }

    /// `+HH`, `+HH:MM` or `+HH:MM:SS` like the server's ISO output.
    static func offsetText(_ secondsEast: Int) -> String {
        let magnitude = abs(secondsEast)
        var text = (secondsEast < 0 ? "-" : "+") + pad2(magnitude / 3600)
        if magnitude % 3600 != 0 { text += ":" + pad2(magnitude / 60 % 60) }
        if magnitude % 60 != 0 { text += ":" + pad2(magnitude % 60) }
        return text
    }

    private static func fraction(_ micros: Int) -> String {
        guard micros != 0 else { return "" }
        var text = String(micros)
        text = String(repeating: "0", count: 6 - text.count) + text
        while text.last == "0" { text.removeLast() }
        return "." + text
    }

    private static func pad2(_ value: Int) -> String { value < 10 ? "0" + String(value) : String(value) }
}
