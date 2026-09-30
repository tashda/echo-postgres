import Foundation
import PostgresNIO
import PostgresWire

/// Automatic retry for result columns whose type has no binary output function.
///
/// PostgresNIO asks for every result column in binary format. A few types (`aclitem`, as in
/// `pg_class.relacl`) have no binary send function, so the server rejects the whole query with SQLSTATE
/// `42883` "no binary output function available for type …". When that happens outside a transaction
/// block, the session rewrites the statement so only those columns are cast to text and runs it again:
///
///     SELECT q.c1 AS "oid", q.c2::text AS "relacl" FROM (<original>) AS q(c1, c2)
///
/// Names come from `row_to_json` and types from `pg_typeof`, so the retry keeps the original column
/// names and order on every server version. Inside a transaction the error
/// has already aborted the transaction, so it is reported instead, with a hint to cast the column.
extension PostgresSessionConnection {

    static func isMissingBinaryOutput(_ error: any Error) -> Bool {
        if let error = error as? PSQLError {
            return error.serverInfo?[.sqlState] == "42883"
                && (error.serverInfo?[.message]?.contains("no binary output function") ?? false)
        }
        if let error = error as? PostgresError {
            return error.sqlState == "42883" && error.message.contains("no binary output function")
        }
        return false
    }

    /// The statement rewritten with text casts for columns that cannot be sent in binary, or `nil`
    /// when it cannot be wrapped as a subquery (not a single `SELECT` / `WITH` / `VALUES` / `TABLE`).
    func textFallbackSQL(for sql: String) async throws -> String? {
        let statements = PostgresSQLSplitter.split(sql)
        guard statements.count == 1, let statement = statements.first?.text,
              let first = PostgresSQLSplitter.leadingWords(statement, count: 1).first,
              ["SELECT", "WITH", "VALUES", "TABLE"].contains(first) || statement.hasPrefix("(") else {
            return nil
        }

        // Names (in order, duplicates kept) from row_to_json; the error implies at least one row.
        let nameRows = try await probeQuery("""
            SELECT k.name FROM (SELECT row_to_json(q) AS j FROM (\(statement)) AS q LIMIT 1) AS x
            CROSS JOIN LATERAL json_object_keys(x.j) WITH ORDINALITY AS k(name, position)
            ORDER BY k.position
            """).rows
        let names = try nameRows.map { try $0.decode(String.self) }
        guard !names.isEmpty else { return nil }
        let aliases = names.indices.map { "c\($0 + 1)" }

        // Types via pg_typeof on positional aliases (works on every server version), then which of
        // them (or whose array element type) have no binary send function.
        let typeList = aliases.map { "pg_typeof(q.\($0))::oid::int8" }.joined(separator: ", ")
        guard let typeRow = try await probeQuery(
            "SELECT \(typeList) FROM (\(statement)) AS q(\(aliases.joined(separator: ", "))) LIMIT 1"
        ).rows.first else { return nil }
        let oids = try typeRow.map { try $0.decode(Int64.self) }
        let flagRows = try await probeQuery("""
            SELECT t.oid::int8, (t.typsend::oid = 0 OR (t.typelem <> 0 AND e.typsend::oid = 0))
            FROM pg_type t LEFT JOIN pg_type e ON e.oid = t.typelem
            WHERE t.oid = ANY('{\(oids.map(String.init).joined(separator: ","))}'::oid[])
            """).rows
        var noBinary: [Int64: Bool] = [:]
        for row in flagRows {
            let (oid, flag) = try row.decode((Int64, Bool).self)
            noBinary[oid] = flag
        }
        let needsText = oids.map { noBinary[$0] ?? false }
        guard needsText.contains(true) else { return nil }

        let columns = names.indices.map { index in
            "q.\(aliases[index])" + (needsText[index] ? "::text" : "") + " AS " + PostgresQuoting.quoteIdentifier(names[index])
        }
        return "SELECT \(columns.joined(separator: ", ")) FROM (\(statement)) AS q(\(aliases.joined(separator: ", ")))"
    }

    /// The hint added when the fallback cannot run (inside a transaction, or not a plain query).
    static let binaryOutputHint = "Cast the column to text in the query, for example relacl::text[]."
}
