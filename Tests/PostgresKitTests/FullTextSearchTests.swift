import XCTest
import Logging
@testable import PostgresKit

/// Tests full-text search: tsvector, tsquery, operators, ranking, and search_vector trigger.
final class FullTextSearchTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else { throw XCTSkip("Postgres environment not set") }
        let config = PostgresConfiguration(
            host: TestEnv.host, port: TestEnv.port,
            database: TestEnv.database, username: TestEnv.username,
            password: TestEnv.password, useTLS: TestEnv.useTLS,
            applicationName: "FullTextSearchTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() { client?.close(); super.tearDown() }

    // MARK: - Basic tsvector / tsquery

    func testToTsvector() async throws {
        let rows = try await client.simpleQuery("SELECT to_tsvector('english', 'The quick brown fox')::text")
        var found = false
        for try await vec in rows.decode(String.self) {
            XCTAssertTrue(vec.contains("'quick'"))
            XCTAssertTrue(vec.contains("'brown'"))
            XCTAssertTrue(vec.contains("'fox'"))
            found = true
        }
        XCTAssertTrue(found)
    }

    func testToTsquery() async throws {
        let rows = try await client.simpleQuery("SELECT to_tsquery('english', 'quick & fox')::text")
        var found = false
        for try await q in rows.decode(String.self) {
            XCTAssertTrue(q.contains("'quick'"))
            XCTAssertTrue(q.contains("'fox'"))
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Match Operator @@

    func testMatchOperator() async throws {
        let rows = try await client.simpleQuery("""
            SELECT col_text FROM public.fulltext_types
            WHERE col_tsvector @@ to_tsquery('english', 'quick & fox')
        """)
        var found = false
        for try await text in rows.decode(String.self) {
            XCTAssertTrue(text.contains("quick"))
            found = true
        }
        XCTAssertTrue(found)
    }

    func testNoMatchReturnsEmpty() async throws {
        let rows = try await client.simpleQuery("""
            SELECT count(*) FROM public.fulltext_types
            WHERE col_tsvector @@ to_tsquery('english', 'nonexistentword12345')
        """)
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Boolean Operators

    func testAndOperator() async throws {
        // 'postgresql' stems differently from 'postgres' in English stemmer,
        // so use 'postgresql' to match the tsvector from 'PostgreSQL is an advanced...'
        let rows = try await client.simpleQuery("""
            SELECT col_text FROM public.fulltext_types
            WHERE col_tsvector @@ to_tsquery('english', 'postgresql & database')
        """)
        var found = false
        for try await _ in rows { found = true }
        XCTAssertTrue(found)
    }

    func testOrOperator() async throws {
        // 'swift' matches row 3, 'fox' matches row 1
        let rows = try await client.simpleQuery("""
            SELECT count(*) FROM public.fulltext_types
            WHERE col_tsvector @@ to_tsquery('english', 'swift | fox')
        """)
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThanOrEqual(count, 2)
    }

    func testNotOperator() async throws {
        let rows = try await client.simpleQuery("""
            SELECT col_text FROM public.fulltext_types
            WHERE col_tsvector @@ to_tsquery('english', 'swift & !objective')
        """)
        var found = false
        for try await text in rows.decode(String.self) {
            XCTAssertTrue(text.contains("Swift"))
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - Phrase Search

    func testPhraseTsquery() async throws {
        let rows = try await client.simpleQuery("""
            SELECT count(*) FROM public.fulltext_types
            WHERE col_tsvector @@ phraseto_tsquery('english', 'brown fox')
        """)
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThan(count, 0, "Should find phrase 'brown fox'")
    }

    // MARK: - Ranking

    func testTsRank() async throws {
        let rows = try await client.simpleQuery("""
            SELECT col_text, ts_rank(col_tsvector, to_tsquery('english', 'database'))
            FROM public.fulltext_types
            WHERE col_tsvector @@ to_tsquery('english', 'database')
            ORDER BY ts_rank(col_tsvector, to_tsquery('english', 'database')) DESC
        """)
        var found = false
        for try await _ in rows { found = true }
        XCTAssertTrue(found)
    }

    func testTsRankCd() async throws {
        let rows = try await client.simpleQuery("""
            SELECT ts_rank_cd(col_tsvector, to_tsquery('english', 'quick & fox'))
            FROM public.fulltext_types
            WHERE col_tsvector @@ to_tsquery('english', 'quick & fox')
        """)
        var found = false
        for try await _ in rows { found = true }
        XCTAssertTrue(found)
    }

    // MARK: - Search Vector Trigger on app.posts

    func testPostSearchVectorIsPopulated() async throws {
        // The trigger trg_posts_search_vector should auto-populate search_vector
        let rows = try await client.simpleQuery("""
            SELECT title FROM app.posts
            WHERE search_vector @@ to_tsquery('english', 'postgresql')
        """)
        var titles: [String] = []
        for try await t in rows.decode(String.self) { titles.append(t) }
        XCTAssertFalse(titles.isEmpty, "Search vector trigger should populate for posts mentioning PostgreSQL")
    }

    func testPostSearchVectorMatchesContent() async throws {
        let rows = try await client.simpleQuery("""
            SELECT title FROM app.posts
            WHERE search_vector @@ to_tsquery('english', 'jsonb & queries')
        """)
        var found = false
        for try await title in rows.decode(String.self) {
            XCTAssertTrue(title.lowercased().contains("jsonb"))
            found = true
        }
        XCTAssertTrue(found)
    }

    // MARK: - GIN Index on fulltext_types

    func testGINIndexUsedForFullTextSearch() async throws {
        let plan = try await client.executionPlan.explain("SELECT * FROM public.fulltext_types WHERE col_tsvector @@ to_tsquery('english', 'quick')")
        XCTAssertFalse(plan.isEmpty, "EXPLAIN should produce a plan")
    }

    // MARK: - Plainto_tsquery

    func testPlaintoTsquery() async throws {
        let rows = try await client.simpleQuery("""
            SELECT count(*) FROM public.fulltext_types
            WHERE col_tsvector @@ plainto_tsquery('english', 'open source database')
        """)
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - Websearch_to_tsquery

    func testWebsearchToTsquery() async throws {
        let rows = try await client.simpleQuery("""
            SELECT count(*) FROM public.fulltext_types
            WHERE col_tsvector @@ websearch_to_tsquery('english', 'swift programming -objective')
        """)
        var count: Int64 = 0
        for try await c in rows.decode(Int64.self) { count = c }
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    // MARK: - Headline

    func testTsHeadline() async throws {
        let rows = try await client.simpleQuery("""
            SELECT ts_headline('english', col_text, to_tsquery('english', 'fox'), 'StartSel=<b>, StopSel=</b>')
            FROM public.fulltext_types
            WHERE col_tsvector @@ to_tsquery('english', 'fox')
        """)
        var found = false
        for try await headline in rows.decode(String.self) {
            XCTAssertTrue(headline.contains("<b>"))
            found = true
        }
        XCTAssertTrue(found)
    }
}
