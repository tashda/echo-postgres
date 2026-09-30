import Foundation

/// Streaming RFC 4180 CSV reader that re-encodes rows as COPY *text* format
/// (tab-separated, `\N` for NULL, backslash escapes), which is what PostgresNIO's `copyFrom` sends.
///
/// Quoted fields may contain delimiters, quotes (doubled) and line breaks, and may span input chunks.
/// Like the server's CSV mode, an unquoted field equal to the NULL string (empty by default) is NULL
/// and a quoted empty field is an empty string.
struct CSVToCopyTextConverter {
    private enum State { case fieldStart, unquoted, quoted, quoteInQuoted }

    private let delimiter: UInt8
    private let quote: UInt8
    private let nullString: [UInt8]
    private var skipRows: Int

    private var state = State.fieldStart
    private var field: [UInt8] = []
    private var fieldWasQuoted = false
    private var row: [[UInt8]?] = []
    private var pendingCarriageReturn = false
    private(set) var rowCount = 0

    init(delimiter: Character, quote: Character, nullString: String?, skipHeader: Bool) throws {
        guard let delimiterByte = delimiter.asciiValue, let quoteByte = quote.asciiValue else {
            throw PostgresKitError.notSupported("COPY CSV delimiter and quote must be ASCII characters")
        }
        self.delimiter = delimiterByte
        self.quote = quoteByte
        self.nullString = Array((nullString ?? "").utf8)
        self.skipRows = skipHeader ? 1 : 0
    }

    /// Feed the next chunk; returns COPY text for every row completed by it.
    mutating func feed(_ bytes: some Sequence<UInt8>, into output: inout [UInt8]) {
        for byte in bytes {
            if pendingCarriageReturn {
                pendingCarriageReturn = false
                if byte == 0x0A { continue }
            }
            switch state {
            case .quoted:
                if byte == quote { state = .quoteInQuoted } else { field.append(byte) }
            case .quoteInQuoted:
                if byte == quote {
                    field.append(quote)
                    state = .quoted
                } else {
                    state = .unquoted
                    handleUnquoted(byte, into: &output)
                }
            case .fieldStart:
                if byte == quote {
                    fieldWasQuoted = true
                    state = .quoted
                } else {
                    state = .unquoted
                    handleUnquoted(byte, into: &output)
                }
            case .unquoted:
                handleUnquoted(byte, into: &output)
            }
        }
    }

    /// Flush a final row without a trailing newline.
    mutating func finish(into output: inout [UInt8]) throws {
        if state == .quoted { throw PostgresKitError.notSupported("Unterminated quoted field at end of CSV data") }
        if state != .fieldStart || !row.isEmpty { endRow(into: &output) }
    }

    private mutating func handleUnquoted(_ byte: UInt8, into output: inout [UInt8]) {
        switch byte {
        case delimiter:
            endField()
        case 0x0A:
            endRow(into: &output)
        case 0x0D:
            endRow(into: &output)
            pendingCarriageReturn = true
        default:
            field.append(byte)
        }
    }

    private mutating func endField() {
        row.append(!fieldWasQuoted && field == nullString ? nil : field)
        field.removeAll(keepingCapacity: true)
        fieldWasQuoted = false
        state = .fieldStart
    }

    private mutating func endRow(into output: inout [UInt8]) {
        endField()
        defer { row.removeAll(keepingCapacity: true) }
        // A blank line is not a row.
        if row.count == 1, row[0]?.isEmpty == true, !fieldWasQuoted { return }
        if skipRows > 0 {
            skipRows -= 1
            return
        }
        for (index, value) in row.enumerated() {
            if index > 0 { output.append(0x09) }
            guard let value else {
                output.append(contentsOf: [0x5C, 0x4E]) // \N
                continue
            }
            for byte in value {
                switch byte {
                case 0x5C: output.append(contentsOf: [0x5C, 0x5C])
                case 0x09: output.append(contentsOf: [0x5C, 0x74])
                case 0x0A: output.append(contentsOf: [0x5C, 0x6E])
                case 0x0D: output.append(contentsOf: [0x5C, 0x72])
                default: output.append(byte)
                }
            }
        }
        output.append(0x0A)
        rowCount += 1
    }
}

/// Writes rows as CSV the way the server's `COPY … TO STDOUT (FORMAT csv)` does: NULL is the NULL
/// string (unquoted, empty by default), an empty string is `""`, and fields containing the delimiter,
/// quote, CR or LF — or equal to the NULL string — are quoted with quotes doubled.
struct CSVWriter {
    let delimiter: Character
    let quote: Character
    let nullString: String

    func line(_ fields: [String?]) -> String {
        var line = ""
        for (index, field) in fields.enumerated() {
            if index > 0 { line.append(delimiter) }
            guard let field else {
                line += nullString
                continue
            }
            let needsQuotes = field.isEmpty || field == nullString
                || field.contains(where: { $0 == delimiter || $0 == quote || $0 == "\n" || $0 == "\r" })
            if needsQuotes {
                line.append(quote)
                for character in field {
                    if character == quote { line.append(quote) }
                    line.append(character)
                }
                line.append(quote)
            } else {
                line += field
            }
        }
        return line + "\n"
    }

    /// COPY text format line (tab separated by default, `\N` for NULL, backslash escapes).
    static func textLine(_ fields: [String?], delimiter: Character) -> String {
        var line = ""
        for (index, field) in fields.enumerated() {
            if index > 0 { line.append(delimiter) }
            guard let field else {
                line += "\\N"
                continue
            }
            for character in field {
                switch character {
                case "\\": line += "\\\\"
                case "\n": line += "\\n"
                case "\r": line += "\\r"
                case "\t": line += "\\t"
                case delimiter: line += "\\" + String(delimiter)
                default: line.append(character)
                }
            }
        }
        return line + "\n"
    }
}
