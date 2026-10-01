/// Minimal Postgres SQL lexer: finds top-level `;`, parentheses and bare words while skipping
/// string literals, quoted identifiers, dollar-quoted bodies and comments.
///
/// It is deliberately not a parser — it only needs to know where statements end and which
/// keywords a statement starts with.
struct PostgresSQLLexer {
    enum Token: Equatable {
        /// A bare word (identifier or keyword), uppercased, with its UTF-8 range.
        case word(String, Range<Int>)
        case semicolon(Int)
        case openParen
        case closeParen
        /// Anything else that is not whitespace or a comment (literals, operators, quoted identifiers).
        case other
    }

    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ sql: String) {
        self.bytes = Array(sql.utf8)
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var utf8Count: Int { bytes.count }

    private func byte(at index: Int) -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte >= 0x80
    }

    private static func isIdentifierPart(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || (byte >= 0x30 && byte <= 0x39) || byte == 0x24
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C
    }

    /// The next significant token, or `nil` at the end of input.
    mutating func next() -> Token? {
        while position < bytes.count {
            let current = bytes[position]
            if Self.isSpace(current) {
                position += 1
                continue
            }
            // -- line comment
            if current == 0x2D, byte(at: position + 1) == 0x2D {
                while position < bytes.count, bytes[position] != 0x0A { position += 1 }
                continue
            }
            // /* block comment */ (nests in Postgres)
            if current == 0x2F, byte(at: position + 1) == 0x2A {
                skipBlockComment()
                continue
            }
            switch current {
            case 0x3B:
                position += 1
                return .semicolon(position - 1)
            case 0x28:
                position += 1
                return .openParen
            case 0x29:
                position += 1
                return .closeParen
            case 0x27:
                skipQuoted(quote: 0x27, backslashEscapes: false)
                return .other
            case 0x22:
                skipQuoted(quote: 0x22, backslashEscapes: false)
                return .other
            case 0x24:
                if skipDollarQuoted() { return .other }
                position += 1
                return .other
            default:
                break
            }
            if Self.isIdentifierStart(current) {
                // E'…' escape strings (also e'…'), but not the tail of a longer word.
                if (current == 0x45 || current == 0x65), byte(at: position + 1) == 0x27 {
                    position += 1
                    skipQuoted(quote: 0x27, backslashEscapes: true)
                    return .other
                }
                let start = position
                while position < bytes.count, Self.isIdentifierPart(bytes[position]) { position += 1 }
                let word = String(decoding: bytes[start..<position], as: UTF8.self).uppercased()
                return .word(word, start..<position)
            }
            // Numbers, operators, parameters ($1 is handled above), casts…
            position += 1
            return .other
        }
        return nil
    }

    private mutating func skipBlockComment() {
        var depth = 0
        while position < bytes.count {
            if bytes[position] == 0x2F, byte(at: position + 1) == 0x2A {
                depth += 1
                position += 2
            } else if bytes[position] == 0x2A, byte(at: position + 1) == 0x2F {
                depth -= 1
                position += 2
                if depth == 0 { return }
            } else {
                position += 1
            }
        }
    }

    /// Skips a quoted run starting at the opening quote. Doubled quotes are part of the value.
    private mutating func skipQuoted(quote: UInt8, backslashEscapes: Bool) {
        position += 1
        while position < bytes.count {
            let current = bytes[position]
            if backslashEscapes, current == 0x5C {
                position += 2
                continue
            }
            if current == quote {
                if byte(at: position + 1) == quote {
                    position += 2
                    continue
                }
                position += 1
                return
            }
            position += 1
        }
    }

    /// Skips `$tag$ … $tag$` if one starts here. `$1`-style parameters are not dollar quotes.
    private mutating func skipDollarQuoted() -> Bool {
        var end = position + 1
        if let first = byte(at: end), Self.isIdentifierStart(first) {
            while let next = byte(at: end), Self.isIdentifierPart(next), next != 0x24 { end += 1 }
        }
        guard byte(at: end) == 0x24 else { return false }
        let delimiter = Array(bytes[position...end])
        var search = end + 1
        while search + delimiter.count <= bytes.count {
            if bytes[search] == 0x24, Array(bytes[search..<(search + delimiter.count)]) == delimiter {
                position = search + delimiter.count
                return true
            }
            search += 1
        }
        position = bytes.count
        return true
    }
}
