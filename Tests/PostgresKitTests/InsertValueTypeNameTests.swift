import Testing
@testable import PostgresKit

@Suite struct InsertValueTypeNameTests {
    @Test(arguments: ["integer", "double precision", "numeric(10,2)", "text[]", "integer[][]", "sales.address",
                      "timestamp with time zone", "character varying(20)", "tstzrange"])
    func plainTypeNamesStayUnquoted(_ name: String) {
        #expect(quoteTypeNameSQL(name) == name)
    }

    @Test func otherNamesAreQuoted() {
        #expect(quoteTypeNameSQL("odd\"type; DROP") == "\"odd\"\"type; DROP\"")
        #expect(quoteTypeNameSQL("My Schema.Type-1") == "\"My Schema\".\"Type-1\"")
    }
}
