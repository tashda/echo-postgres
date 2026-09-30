import Foundation

/// One statement of a SQL script.
public struct PostgresSQLStatement: Sendable, Equatable {
    /// The statement text without its terminating `;` and surrounding whitespace.
    public let text: String
    /// Position of ``text`` in the original script.
    public let range: Range<String.Index>
    /// Position of ``text`` in the original script in UTF-16 code units (for `NSRange` based editors).
    public let utf16Range: Range<Int>
    /// Zero-based position of the statement in the script.
    public let index: Int
}

/// How a statement affects the session's transaction.
public enum PostgresTransactionEffect: Sendable, Equatable {
    case none
    /// `BEGIN`, `START TRANSACTION`
    case begin
    /// `COMMIT`, `END`, `ROLLBACK`, `ABORT`, `PREPARE TRANSACTION` — the transaction block ends.
    case end
    /// `COMMIT AND CHAIN`, `ROLLBACK AND CHAIN` — a new transaction starts immediately.
    case chain
    /// `ROLLBACK TO SAVEPOINT` — recovers a failed transaction.
    case rollbackToSavepoint
}

/// Splits Postgres SQL scripts into statements the way `psql` does.
///
/// PostgresNIO runs every query through the extended protocol, which accepts exactly one statement,
/// so scripts must be split client-side. The splitter understands `'…'`, `E'…'`, `"…"`,
/// `$tag$…$tag$`, `--` and nested `/* */` comments, and SQL-standard function bodies
/// (`BEGIN ATOMIC … END`), which contain semicolons that do not end the statement.
public enum PostgresSQLSplitter {

    /// Split `sql` into statements. Empty statements (only whitespace or comments) are dropped.
    public static func split(_ sql: String) -> [PostgresSQLStatement] {
        var lexer = PostgresSQLLexer(sql)
        var boundaries: [Range<Int>] = []
        var statementStart = 0
        var atomicDepth = 0
        var sawSignificantToken = false
        var previousWord: String?

        func finish(at end: Int) {
            if sawSignificantToken { boundaries.append(statementStart..<end) }
            sawSignificantToken = false
            previousWord = nil
        }

        while let token = lexer.next() {
            switch token {
            case .semicolon(let offset):
                if atomicDepth == 0 {
                    finish(at: offset)
                    statementStart = offset + 1
                } else {
                    previousWord = nil
                }
            case .word(let word, _):
                sawSignificantToken = true
                if word == "ATOMIC", previousWord == "BEGIN" {
                    atomicDepth += 1
                } else if atomicDepth > 0, word == "CASE" {
                    atomicDepth += 1
                } else if atomicDepth > 0, word == "END" {
                    atomicDepth -= 1
                }
                previousWord = word
            default:
                sawSignificantToken = true
                previousWord = nil
            }
        }
        finish(at: lexer.utf8Count)

        var statements: [PostgresSQLStatement] = []
        let utf8 = sql.utf8
        for bounds in boundaries {
            var lower = utf8.index(utf8.startIndex, offsetBy: bounds.lowerBound)
            var upper = utf8.index(utf8.startIndex, offsetBy: bounds.upperBound)
            while lower < upper, sql[lower].isWhitespace { lower = sql.index(after: lower) }
            while upper > lower, sql[sql.index(before: upper)].isWhitespace { upper = sql.index(before: upper) }
            guard lower < upper else { continue }
            let utf16Lower = sql.utf16.distance(from: sql.utf16.startIndex, to: lower)
            let utf16Upper = utf16Lower + sql.utf16.distance(from: lower, to: upper)
            statements.append(PostgresSQLStatement(
                text: String(sql[lower..<upper]),
                range: lower..<upper,
                utf16Range: utf16Lower..<utf16Upper,
                index: statements.count
            ))
        }
        return statements
    }

    /// The first bare words of a statement (skipping comments and leading parentheses), uppercased.
    static func leadingWords(_ statement: String, count: Int) -> [String] {
        var lexer = PostgresSQLLexer(statement)
        var words: [String] = []
        while words.count < count, let token = lexer.next() {
            switch token {
            case .word(let word, _): words.append(word)
            case .openParen where words.isEmpty: continue
            default: return words
            }
        }
        return words
    }

    /// Whether a statement is expected to return rows (`SELECT`, `WITH`, `VALUES`, `TABLE`, `SHOW`,
    /// `EXPLAIN`, `FETCH`, `CALL`, or anything with a top-level `RETURNING`).
    ///
    /// Row-returning statements should be streamed; the others can be run with a buffered call that
    /// also reports the command tag (`UPDATE 3`). The check errs towards "returns rows".
    public static func returnsRows(_ statement: String) -> Bool {
        var lexer = PostgresSQLLexer(statement)
        var first: String?
        var depth = 0
        while let token = lexer.next() {
            switch token {
            case .openParen:
                if first == nil { return true }
                depth += 1
            case .closeParen:
                depth -= 1
            case .word(let word, _):
                if first == nil {
                    first = word
                    if ["SELECT", "WITH", "VALUES", "TABLE", "SHOW", "EXPLAIN", "FETCH", "CALL"].contains(word) {
                        return true
                    }
                } else if depth == 0, word == "RETURNING" {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    /// How a statement changes the transaction state of the session that runs it.
    public static func transactionEffect(of statement: String) -> PostgresTransactionEffect {
        let words = leadingWords(statement, count: 4)
        guard let first = words.first else { return .none }
        let rest = Array(words.dropFirst())
        let chained = rest.starts(with: ["AND", "CHAIN"]) || rest.dropFirst().starts(with: ["AND", "CHAIN"])
        switch first {
        case "BEGIN":
            return .begin
        case "START":
            return rest.first == "TRANSACTION" ? .begin : .none
        case "COMMIT", "END":
            if rest.first == "PREPARED" { return .none }
            return chained ? .chain : .end
        case "ROLLBACK", "ABORT":
            if rest.first == "PREPARED" { return .none }
            if rest.first == "TO" || (rest.count > 1 && rest[1] == "TO") { return .rollbackToSavepoint }
            return chained ? .chain : .end
        case "PREPARE":
            return rest.first == "TRANSACTION" ? .end : .none
        default:
            return .none
        }
    }
}
