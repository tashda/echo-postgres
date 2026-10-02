import Foundation
import Logging
import XCTest
@testable import PostgresKit

/// COPY statement parsing (no database needed).
final class CopyParsingTests: XCTestCase {
    func testParsesStatementForms() throws {
        let modern = try CopyStatement.parse(sql: "COPY \"My Schema\".\"Weird\"\"Table\" (a, \"B c\") FROM STDIN WITH (FORMAT csv, HEADER true, NULL 'x');")
        XCTAssertEqual(modern.direction, .in)
        XCTAssertEqual(modern.schema, "My Schema")
        XCTAssertEqual(modern.table, "Weird\"Table")
        XCTAssertEqual(modern.columns, ["a", "B c"])
        XCTAssertEqual(modern.format, .csv)
        XCTAssertTrue(modern.header)
        XCTAssertEqual(modern.nullString, "x")
        XCTAssertEqual(modern.delimiter, ",")

        let legacy = try CopyStatement.parse(sql: "copy Users to stdout with csv header delimiter ';'")
        XCTAssertEqual(legacy.table, "users")
        XCTAssertEqual(legacy.delimiter, ";")
        XCTAssertTrue(legacy.header)

        let query = try CopyStatement.parse(sql: "COPY (SELECT f(x) FROM t WHERE y = ')') TO STDOUT (FORMAT csv)")
        XCTAssertEqual(query.query, "SELECT f(x) FROM t WHERE y = ')'")

        let text = try CopyStatement.parse(sql: "COPY t FROM STDIN")
        XCTAssertEqual(text.format, .text)
        XCTAssertEqual(text.delimiter, "\t")
        XCTAssertThrowsError(try CopyStatement.parse(sql: "COPY t FROM '/etc/passwd'"))
        XCTAssertEqual(try CopyStatement.parse(sql: "COPY t TO STDOUT (FORMAT binary)").format, .binary)
        XCTAssertEqual(try CopyStatement.parse(sql: "COPY t FROM STDIN BINARY").format, .binary)
    }
}

/// COPY against a server: real COPY protocol in, faithful CSV out.
final class BulkCopyEdgeCaseTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        client = try await PostgresKit.PostgresClient.connect(configuration: TestEnv.configuration(applicationName: "BulkCopyEdgeCases"), logger: logger)
    }

    override func tearDown() {
        client?.close()
        super.tearDown()
    }

    private var bulk: PostgresBulkCopy { PostgresBulkCopy(client: client, logger: logger) }

    private func stream(_ text: String, chunk: Int = 7) -> AsyncThrowingStream<Data, Error> {
        let bytes = Array(text.utf8)
        return AsyncThrowingStream { continuation in
            var index = 0
            while index < bytes.count {
                continuation.yield(Data(bytes[index..<min(index + chunk, bytes.count)]))
                index += chunk
            }
            continuation.finish()
        }
    }

    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> String {
        var data = Data()
        for try await chunk in stream { data.append(chunk) }
        return String(decoding: data, as: UTF8.self)
    }

    func testCSVRoundTripKeepsNullsEmptyStringsAndLineBreaks() async throws {
        let table = "copy_edge_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await client.simpleQueryResult("CREATE SCHEMA IF NOT EXISTS \"Copy Schema\"")
        _ = try await client.simpleQueryResult("CREATE TABLE \"Copy Schema\".\"\(table)\" (id int, note text, tags text[], at timestamptz)")
        defer { Task { [client = client!] in _ = try? await client.simpleQueryResult("DROP TABLE IF EXISTS \"Copy Schema\".\"\(table)\"") } }

        let csv = "id,note,tags,at\n1,\"multi\nline, with comma\",\"{a,\"\"b c\"\"}\",2024-01-01 00:00:00+00\n2,,{},\n3,\"\",,\n"
        try await bulk.copyIn(sql: "COPY \"Copy Schema\".\"\(table)\" FROM STDIN WITH (FORMAT csv, HEADER true)", source: stream(csv))

        let check = try await client.simpleQueryResult("SELECT count(*) FILTER (WHERE note IS NULL), count(*) FILTER (WHERE note = ''), max(note) FROM \"Copy Schema\".\"\(table)\"")
        let row = try XCTUnwrap(check.rows.first)
        let (nulls, empties, note) = try row.decode((Int, Int, String).self)
        XCTAssertEqual(nulls, 1)
        XCTAssertEqual(empties, 1)
        XCTAssertEqual(note, "multi\nline, with comma")

        let exported = try await collect(try await bulk.copyOut(sql: "COPY (SELECT id, note, tags FROM \"Copy Schema\".\"\(table)\" ORDER BY id) TO STDOUT WITH (FORMAT csv, HEADER true)"))
        XCTAssertEqual(exported, "id,note,tags\n1,\"multi\nline, with comma\",\"{a,\"\"b c\"\"}\"\n2,,{}\n3,\"\",\n")
    }

    func testCopyInIsAtomic() async throws {
        let table = "copy_atomic_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await client.simpleQueryResult("CREATE TABLE \(table) (id int NOT NULL)")
        defer { Task { [client = client!] in _ = try? await client.simpleQueryResult("DROP TABLE IF EXISTS \(table)") } }
        do {
            try await bulk.copyIn(sql: "COPY \(table) FROM STDIN (FORMAT csv)", source: stream("1\n2\nnot a number\n4\n"))
            XCTFail("a bad row must fail the COPY")
        } catch let error as PostgresError {
            XCTAssertEqual(error.sqlState, "22P02")
        }
        let count = try await client.simpleQueryResult("SELECT count(*) FROM \(table)")
        XCTAssertEqual(try count.rows.first?.decode(Int.self), 0, "no partial import")
    }

    func testTextFormatPassesThrough() async throws {
        let table = "copy_text_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await client.simpleQueryResult("CREATE TABLE \(table) (id int, note text)")
        defer { Task { [client = client!] in _ = try? await client.simpleQueryResult("DROP TABLE IF EXISTS \(table)") } }
        try await bulk.copyIn(sql: "COPY \(table) (id, note) FROM STDIN", source: stream("1\ttab\\there\n2\t\\N\n"))
        let exported = try await collect(try await bulk.copyOut(sql: "COPY \(table) TO STDOUT"))
        XCTAssertEqual(exported, "1\ttab\\there\n2\t\\N\n")
    }
}
