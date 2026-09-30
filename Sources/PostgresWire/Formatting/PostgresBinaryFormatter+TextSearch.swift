extension PostgresBinaryFormatter {
    // MARK: - tsvector

    /// `tsvectorsend`: lexeme count, then per lexeme a NUL-terminated string, a position count and
    /// 16-bit positions (weight in the top two bits: 3 = A, 2 = B, 1 = C, 0 = D).
    static func formatTSVector(_ reader: inout PostgresBinaryReader) throws -> String {
        let count = Int(try reader.read(Int32.self))
        guard count >= 0 else { throw PostgresBinaryFormatError() }
        var lexemes: [String] = []
        for _ in 0..<count {
            var text = quotedLexeme(try reader.readCString())
            let positionCount = Int(try reader.read(UInt16.self))
            var positions: [String] = []
            for _ in 0..<positionCount {
                let raw = try reader.read(UInt16.self)
                let weight = raw >> 14
                positions.append(String(raw & 0x3FFF) + (weight == 3 ? "A" : weight == 2 ? "B" : weight == 1 ? "C" : ""))
            }
            if !positions.isEmpty { text += ":" + positions.joined(separator: ",") }
            lexemes.append(text)
        }
        try reader.expectEnd()
        return lexemes.joined(separator: " ")
    }

    static func quotedLexeme(_ lexeme: String) -> String {
        var text = "'"
        for character in lexeme {
            if character == "'" || character == "\\" { text.append(character) }
            text.append(character)
        }
        return text + "'"
    }

    // MARK: - tsquery

    private enum QueryItem {
        case operand(value: String, weight: UInt8, prefix: Bool)
        case not
        case binary(op: UInt8, distance: Int16)
    }

    private static let operatorAnd: UInt8 = 2
    private static let operatorOr: UInt8 = 3
    private static let operatorPhrase: UInt8 = 4

    /// `tsquerysend`: item count, then items in prefix order. For a binary operator the right operand
    /// follows immediately and the left operand follows the right one.
    static func formatTSQuery(_ reader: inout PostgresBinaryReader) throws -> String {
        let count = Int(try reader.read(Int32.self))
        guard count >= 0 else { throw PostgresBinaryFormatError() }
        var items: [QueryItem] = []
        for _ in 0..<count {
            switch try reader.read(UInt8.self) {
            case 1:
                let weight = try reader.read(UInt8.self)
                let prefix = try reader.read(UInt8.self) != 0
                items.append(.operand(value: try reader.readCString(), weight: weight, prefix: prefix))
            case 2:
                let op = try reader.read(UInt8.self)
                if op == 1 {
                    items.append(.not)
                } else {
                    let distance = op == operatorPhrase ? try reader.read(Int16.self) : 0
                    items.append(.binary(op: op, distance: distance))
                }
            default:
                throw PostgresBinaryFormatError()
            }
        }
        try reader.expectEnd()
        guard !items.isEmpty else { return "" }

        var index = 0
        func priority(_ item: QueryItem) -> Int {
            switch item {
            case .operand: return 5
            case .not: return 4
            case .binary(let op, _): return op == operatorPhrase ? 3 : op == operatorAnd ? 2 : 1
            }
        }
        // Mirrors the server's infix(): parenthesise lower-priority operands, and a phrase operator
        // that is the right operand of another phrase operator.
        func infix(parentPriority: Int, rightPhraseOperand: Bool) throws -> String {
            guard index < items.count else { throw PostgresBinaryFormatError() }
            let item = items[index]
            index += 1
            switch item {
            case .operand(let value, let weight, let prefix):
                var text = quotedLexeme(value)
                if prefix || weight != 0 {
                    text += ":" + (prefix ? "*" : "")
                    for (bit, letter) in [(3, "A"), (2, "B"), (1, "C"), (0, "D")] where weight & (1 << bit) != 0 {
                        text += letter
                    }
                }
                return text
            case .not:
                // A lower-priority operand parenthesises itself: !( 'a' & 'b' ).
                let text = "!" + (try infix(parentPriority: priority(item), rightPhraseOperand: false))
                return priority(item) < parentPriority ? "( " + text + " )" : text
            case .binary(let op, let distance):
                let ownPriority = priority(item)
                let right = try infix(parentPriority: ownPriority, rightPhraseOperand: op == operatorPhrase)
                let left = try infix(parentPriority: ownPriority, rightPhraseOperand: false)
                let symbol: String
                switch op {
                case operatorAnd: symbol = " & "
                case operatorOr: symbol = " | "
                case operatorPhrase: symbol = distance == 1 ? " <-> " : " <\(distance)> "
                default: throw PostgresBinaryFormatError()
                }
                let text = left + symbol + right
                let needsParentheses = ownPriority < parentPriority || (rightPhraseOperand && op == operatorPhrase)
                return needsParentheses ? "( " + text + " )" : text
            }
        }
        let text = try infix(parentPriority: 0, rightPhraseOperand: false)
        guard index == items.count else { throw PostgresBinaryFormatError() }
        return text
    }
}
