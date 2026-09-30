import Foundation
import PostgresWire

/// Internal parser for the `COPY` statements accepted by ``PostgresBulkCopy``.
///
/// Supports `COPY table [(columns)] FROM STDIN …`, `COPY table [(columns)] TO STDOUT …` and
/// `COPY (query) TO STDOUT …`, with options in the modern `WITH (FORMAT csv, HEADER true, …)` form
/// or the legacy `WITH CSV HEADER DELIMITER ','` form.
internal struct CopyStatement {
    enum Direction { case `in`, out }
    enum Format { case csv, text, binary }

    var direction: Direction
    var schema: String?
    var table: String?
    var columns: [String] = []
    var query: String?
    var format: Format = .text
    var header = false
    var delimiter: Character = "\t"
    var nullString: String? = nil
    var quote: Character = "\""

    static func parse(sql: String) throws -> CopyStatement {
        let source = Array(sql.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";")))
        var index = 0
        func skipSpace() { while index < source.count, source[index].isWhitespace { index += 1 } }
        func keyword(_ word: String) -> Bool {
            skipSpace()
            let end = index + word.count
            guard end <= source.count, String(source[index..<end]).uppercased() == word else { return false }
            if end < source.count, source[end].isLetter || source[end].isNumber || source[end] == "_" { return false }
            index = end
            return true
        }
        /// Text up to the parenthesis that closes the one at `index`, skipping quoted runs.
        func parenthesised() throws -> String {
            guard index < source.count, source[index] == "(" else { throw PostgresKitError.notSupported("Malformed COPY statement") }
            var depth = 0
            var quoteCharacter: Character?
            let start = index + 1
            while index < source.count {
                let character = source[index]
                if let open = quoteCharacter {
                    if character == open { quoteCharacter = nil }
                } else if character == "'" || character == "\"" {
                    quoteCharacter = character
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        index += 1
                        return String(source[start..<(index - 1)])
                    }
                }
                index += 1
            }
            throw PostgresKitError.notSupported("Unbalanced parentheses in COPY statement")
        }
        /// One identifier, unquoting `"…"`.
        func identifier() throws -> String {
            skipSpace()
            guard index < source.count else { throw PostgresKitError.notSupported("Missing name in COPY statement") }
            if source[index] == "\"" {
                var name = ""
                index += 1
                while index < source.count {
                    if source[index] == "\"" {
                        if index + 1 < source.count, source[index + 1] == "\"" {
                            name.append("\"")
                            index += 2
                            continue
                        }
                        index += 1
                        return name
                    }
                    name.append(source[index])
                    index += 1
                }
                throw PostgresKitError.notSupported("Unterminated quoted name in COPY statement")
            }
            let start = index
            while index < source.count, source[index].isLetter || source[index].isNumber || source[index] == "_" || source[index] == "$" {
                index += 1
            }
            guard index > start else { throw PostgresKitError.notSupported("Malformed name in COPY statement") }
            // Unquoted identifiers fold to lower case, like the server does.
            return String(source[start..<index]).lowercased()
        }

        guard keyword("COPY") else { throw PostgresKitError.notSupported("Not a COPY statement") }
        var statement = CopyStatement(direction: .out)
        skipSpace()
        if index < source.count, source[index] == "(" {
            statement.query = try parenthesised().trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let first = try identifier()
            skipSpace()
            if index < source.count, source[index] == "." {
                index += 1
                statement.schema = first
                statement.table = try identifier()
            } else {
                statement.table = first
            }
            skipSpace()
            if index < source.count, source[index] == "(" {
                statement.columns = try CopyStatement.parseColumnList(try parenthesised())
            }
        }

        if keyword("FROM") {
            guard keyword("STDIN") else { throw PostgresKitError.notSupported("Only COPY … FROM STDIN is supported") }
            statement.direction = .in
        } else if keyword("TO") {
            guard keyword("STDOUT") else { throw PostgresKitError.notSupported("Only COPY … TO STDOUT is supported") }
            statement.direction = .out
        } else {
            throw PostgresKitError.notSupported("Expected FROM STDIN or TO STDOUT")
        }
        if statement.query != nil, statement.direction == .in {
            throw PostgresKitError.notSupported("COPY (query) only works with TO STDOUT")
        }

        _ = keyword("WITH")
        skipSpace()
        let options: String
        if index < source.count, source[index] == "(" {
            options = try parenthesised()
        } else {
            options = String(source[index...])
        }
        try statement.applyOptions(options)
        return statement
    }

    private static func parseColumnList(_ list: String) throws -> [String] {
        try list.split(separator: ",").map { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
                return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
            }
            guard !trimmed.isEmpty else { throw PostgresKitError.notSupported("Empty column name in COPY statement") }
            return trimmed.lowercased()
        }
    }

    /// Reads `FORMAT`, `CSV`, `HEADER`, `DELIMITER`, `NULL` and `QUOTE` from either option syntax.
    private mutating func applyOptions(_ options: String) throws {
        let tokens = Self.optionTokens(options)
        var index = 0
        func value() -> String? {
            guard index + 1 < tokens.count else { return nil }
            index += 1
            return tokens[index].value
        }
        while index < tokens.count {
            let token = tokens[index]
            guard !token.quoted else { index += 1; continue }
            switch token.value.uppercased() {
            case "FORMAT":
                switch value()?.lowercased() {
                case "csv": format = .csv
                case "text": format = .text
                case "binary": format = .binary
                default: throw PostgresKitError.notSupported("Unknown COPY format")
                }
            case "CSV":
                format = .csv
            case "BINARY":
                format = .binary
            case "HEADER":
                header = true
                if index + 1 < tokens.count, ["TRUE", "FALSE", "ON", "OFF", "1", "0", "MATCH"].contains(tokens[index + 1].value.uppercased()) {
                    header = !["FALSE", "OFF", "0"].contains(value()?.uppercased() ?? "")
                }
            case "DELIMITER":
                if let delimiterValue = value(), let character = delimiterValue.first { delimiter = character }
            case "NULL":
                nullString = value()
            case "QUOTE":
                if let quoteValue = value(), let character = quoteValue.first { quote = character }
            default:
                break
            }
            index += 1
        }
        if format == .csv, !options.uppercased().contains("DELIMITER") { delimiter = "," }
    }

    private static func optionTokens(_ options: String) -> [(value: String, quoted: Bool)] {
        var tokens: [(String, Bool)] = []
        var current = ""
        var inQuote = false
        var iterator = Array(options).makeIterator()
        var lookahead = iterator.next()
        func flush() {
            if !current.isEmpty { tokens.append((current, false)) }
            current = ""
        }
        while let character = lookahead {
            lookahead = iterator.next()
            if inQuote {
                if character == "'" {
                    if lookahead == "'" {
                        current.append("'")
                        lookahead = iterator.next()
                    } else {
                        tokens.append((current, true))
                        current = ""
                        inQuote = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "'" {
                flush()
                inQuote = true
            } else if character.isWhitespace || character == "," || character == "(" || character == ")" {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return tokens
    }

    /// The `SELECT` that produces the rows for `COPY … TO STDOUT`.
    var selectSQL: String {
        if let query { return query }
        let columnList = columns.isEmpty ? "*" : columns.map(PostgresQuoting.quoteIdentifier).joined(separator: ", ")
        return "SELECT \(columnList) FROM \(qualifiedTableName)"
    }

    var qualifiedTableName: String {
        let table = PostgresQuoting.quoteIdentifier(self.table ?? "")
        return schema.map { PostgresQuoting.quoteIdentifier($0) + "." + table } ?? table
    }
}
