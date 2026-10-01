import XCTest
@testable import PostgresKit

final class PostgresSQLSplitterTests: XCTestCase {
    private func texts(_ sql: String) -> [String] {
        PostgresSQLSplitter.split(sql).map(\.text)
    }

    func testSplitsOnTopLevelSemicolons() {
        XCTAssertEqual(texts("SELECT 1; SELECT 2;\n  SELECT 3"), ["SELECT 1", "SELECT 2", "SELECT 3"])
        XCTAssertEqual(texts(";;  ;"), [])
        XCTAssertEqual(texts("-- only a comment\n;/* and another */"), [])
    }

    func testIgnoresSemicolonsInLiteralsAndComments() {
        XCTAssertEqual(texts("SELECT 'a;b', \"c;d\" FROM t; SELECT 2"), ["SELECT 'a;b', \"c;d\" FROM t", "SELECT 2"])
        XCTAssertEqual(texts("SELECT 'it''s; fine'; SELECT 2"), ["SELECT 'it''s; fine'", "SELECT 2"])
        XCTAssertEqual(texts(#"SELECT E'x\';y'; SELECT 2"#), [#"SELECT E'x\';y'"#, "SELECT 2"])
        XCTAssertEqual(texts("SELECT 1 -- ; not here\n; SELECT 2"), ["SELECT 1 -- ; not here", "SELECT 2"])
        XCTAssertEqual(texts("SELECT /* a /* nested ; */ still ; comment */ 1; SELECT 2"),
                       ["SELECT /* a /* nested ; */ still ; comment */ 1", "SELECT 2"])
    }

    func testDollarQuotedBodies() {
        let function = """
        CREATE FUNCTION f() RETURNS int AS $$
        BEGIN
          RETURN 1;
        END;
        $$ LANGUAGE plpgsql
        """
        XCTAssertEqual(texts(function + "; SELECT f()").count, 2)
        XCTAssertEqual(texts("DO $body$ BEGIN PERFORM 1; END $body$; SELECT $1::int"), ["DO $body$ BEGIN PERFORM 1; END $body$", "SELECT $1::int"])
    }

    func testBeginAtomicBodies() {
        let sql = """
        CREATE FUNCTION g(a int) RETURNS int LANGUAGE sql
        BEGIN ATOMIC
          SELECT CASE WHEN a > 0 THEN 1 ELSE 0 END;
          SELECT 2;
        END;
        SELECT g(1);
        """
        let statements = texts(sql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].hasSuffix("END"))
        XCTAssertEqual(statements[1], "SELECT g(1)")
    }

    func testRangesPointIntoTheScript() {
        let sql = "SELECT 1;\nSELECT 'ü';"
        let statements = PostgresSQLSplitter.split(sql)
        XCTAssertEqual(statements.map(\.index), [0, 1])
        XCTAssertEqual(String(sql[statements[1].range]), "SELECT 'ü'")
        let nsString = sql as NSString
        XCTAssertEqual(nsString.substring(with: NSRange(location: statements[1].utf16Range.lowerBound, length: statements[1].utf16Range.count)), "SELECT 'ü'")
    }

    func testReturnsRows() {
        XCTAssertTrue(PostgresSQLSplitter.returnsRows("select * from t"))
        XCTAssertTrue(PostgresSQLSplitter.returnsRows("  -- c\n WITH x AS (SELECT 1) SELECT * FROM x"))
        XCTAssertTrue(PostgresSQLSplitter.returnsRows("(SELECT 1) UNION (SELECT 2)"))
        XCTAssertTrue(PostgresSQLSplitter.returnsRows("INSERT INTO t VALUES (1) RETURNING id"))
        XCTAssertTrue(PostgresSQLSplitter.returnsRows("EXPLAIN ANALYZE SELECT 1"))
        XCTAssertFalse(PostgresSQLSplitter.returnsRows("UPDATE t SET a = 'RETURNING'"))
        XCTAssertFalse(PostgresSQLSplitter.returnsRows("CREATE TABLE t (id int)"))
        XCTAssertFalse(PostgresSQLSplitter.returnsRows("INSERT INTO t SELECT * FROM (SELECT 1 RETURNING) x"))
    }

    func testTransactionEffects() {
        XCTAssertEqual(PostgresSQLSplitter.transactionEffect(of: "begin"), .begin)
        XCTAssertEqual(PostgresSQLSplitter.transactionEffect(of: "START TRANSACTION ISOLATION LEVEL SERIALIZABLE"), .begin)
        XCTAssertEqual(PostgresSQLSplitter.transactionEffect(of: "COMMIT"), .end)
        XCTAssertEqual(PostgresSQLSplitter.transactionEffect(of: "end"), .end)
        XCTAssertEqual(PostgresSQLSplitter.transactionEffect(of: "ROLLBACK"), .end)
        XCTAssertEqual(PostgresSQLSplitter.transactionEffect(of: "abort work"), .end)
        XCTAssertEqual(PostgresSQLSplitter.transactionEffect(of: "COMMIT AND CHAIN"), .chain)
        XCTAssertEqual(PostgresSQLSplitter.transactionEffect(of: "ROLLBACK TO SAVEPOINT s1"), .rollbackToSavepoint)
        XCTAssertEqual(PostgresSQLSplitter.transactionEffect(of: "ROLLBACK WORK TO s1"), .rollbackToSavepoint)
        XCTAssertEqual(PostgresSQLSplitter.transactionEffect(of: "PREPARE TRANSACTION 'x'"), .end)
        XCTAssertEqual(PostgresSQLSplitter.transactionEffect(of: "COMMIT PREPARED 'x'"), .none)
        XCTAssertEqual(PostgresSQLSplitter.transactionEffect(of: "SELECT 1"), .none)
        XCTAssertEqual(PostgresSQLSplitter.transactionEffect(of: "/* c */ BEGIN"), .begin)
    }
}

final class PostgresQuotingTests: XCTestCase {
    func testIdentifiers() {
        XCTAssertEqual(PostgresQuoting.quoteIdentifier("my \"table\""), "\"my \"\"table\"\"\"")
        XCTAssertEqual(PostgresQuoting.quoteQualifiedIdentifier("app.users"), "\"app\".\"users\"")
        XCTAssertEqual(PostgresQuoting.quoteQualifiedIdentifier("users"), "\"users\"")
        XCTAssertEqual(PostgresQuoting.quoteQualifiedIdentifier("a.b.c"), "\"a\".\"b.c\"", "only the first dot separates the schema")
        XCTAssertEqual(PostgresQuoting.quoteQualifiedIdentifier("\"my.schema\".t"), "\"my.schema\".\"t\"")
        XCTAssertEqual(PostgresQuoting.quoteQualifiedIdentifier("s.\"we\"\"ird\""), "\"s\".\"we\"\"ird\"")
    }

    func testLiterals() {
        XCTAssertEqual(PostgresQuoting.quoteLiteral("it's"), "'it''s'")
        XCTAssertEqual(PostgresQuoting.quoteLiteral(#"a\b"#), #"E'a\\b'"#)
        XCTAssertEqual(PostgresQuoting.quoteLiteral("x'); DROP TABLE t; --"), "'x''); DROP TABLE t; --'")
    }
}
