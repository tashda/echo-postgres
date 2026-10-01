import Testing
@testable import PostgresKit

@Suite struct InsertValueTypeNameTests {
    @Test(arguments: ["integer", "double precision", "numeric(10,2)", "text[]", "integer[][]", "sales.address",
                      "timestamp with time zone", "character varying(20)", "tstzrange", "TIMESTAMP(3) WITHOUT TIME ZONE", "bit varying(8)"])
    func plainTypeNamesStayUnquoted(_ name: String) {
        #expect(quoteTypeNameSQL(name) == name)
    }

    @Test func otherNamesAreQuoted() {
        #expect(quoteTypeNameSQL("odd\"type; DROP") == "\"odd\"\"type; DROP\"")
        #expect(quoteTypeNameSQL("My Schema.Type-1") == "\"My Schema\".\"Type-1\"")
        #expect(quoteTypeNameSQL("My Schema.Type") == "\"My Schema\".\"Type\"")
    }

    /// Words that are not one of SQL's multi-word type names are SQL, so they are quoted.
    @Test func otherWordsAreNeverLeftUnquoted() {
        #expect(quoteTypeNameSQL("text union select usename from pg_user") == "\"text union select usename from pg_user\"")
        #expect(quoteTypeNameSQL("integer or true") == "\"integer or true\"")
    }
}
