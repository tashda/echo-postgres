/// Quoting for identifiers and literals that must be spliced into SQL text (DDL, utility commands).
///
/// Prefer bind parameters (`$1`) wherever the server accepts them; these helpers are for places it
/// does not (object names, `CREATE ROLE … PASSWORD`, `SET`, `COMMENT ON`, …).
public enum PostgresQuoting {

    /// Quote one identifier: `my "table"` → `"my ""table"""`.
    public static func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Quote a possibly schema-qualified name.
    ///
    /// The first dot outside double quotes separates schema and name (`app.users` → `"app"."users"`;
    /// later dots belong to the name). Parts that are already double-quoted are unquoted first, so a
    /// schema that itself contains a dot can be passed as `"my.schema".users`.
    public static func quoteQualifiedIdentifier(_ name: String) -> String {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = Array(name).makeIterator()
        var lookahead: Character? = iterator.next()
        while let character = lookahead {
            lookahead = iterator.next()
            if inQuotes {
                if character == "\"" {
                    if lookahead == "\"" {
                        current.append("\"")
                        lookahead = iterator.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" && current.isEmpty {
                inQuotes = true
            } else if character == "." && parts.isEmpty {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map(quoteIdentifier).joined(separator: ".")
    }

    /// Quote a string literal the way libpq's `PQescapeLiteral` does: quotes are doubled, and when the
    /// value contains a backslash it is written as an `E'…'` string with backslashes doubled, which is
    /// correct whatever `standard_conforming_strings` is set to.
    public static func quoteLiteral(_ value: String) -> String {
        let quoted = value.replacingOccurrences(of: "'", with: "''")
        if value.contains("\\") {
            return "E'" + quoted.replacingOccurrences(of: "\\", with: "\\\\") + "'"
        }
        return "'" + quoted + "'"
    }
}
