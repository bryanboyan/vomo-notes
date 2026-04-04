import Testing
@testable import Vomo

@Suite("DQL Parser")
struct DQLParserTests {

    // MARK: - Tokenizer

    @Test("Tokenizes simple TABLE query")
    func tokenizeTable() {
        var tokenizer = DQLTokenizer("TABLE rating FROM \"Books\"")
        let tokens = tokenizer.tokenize()
        #expect(tokens[0] == .keyword(.table))
        #expect(tokens[1] == .identifier("rating"))
        #expect(tokens[2] == .keyword(.from))
        #expect(tokens[3] == .string("Books"))
        #expect(tokens[4] == .eof)
    }

    @Test("Tokenizes operators")
    func tokenizeOperators() {
        var tokenizer = DQLTokenizer("rating > 7")
        let tokens = tokenizer.tokenize()
        #expect(tokens[0] == .identifier("rating"))
        #expect(tokens[1] == .op(">"))
        #expect(tokens[2] == .number(7))
    }

    @Test("Tokenizes compound operators")
    func tokenizeCompoundOps() {
        var tokenizer = DQLTokenizer("a != b AND c <= 5 OR d >= 10")
        let tokens = tokenizer.tokenize()
        #expect(tokens[1] == .op("!="))
        #expect(tokens[5] == .op("<="))
        #expect(tokens[9] == .op(">="))
    }

    @Test("Tokenizes arithmetic operators")
    func tokenizeArithmetic() {
        var tokenizer = DQLTokenizer("a + b - c * d / e")
        let tokens = tokenizer.tokenize()
        #expect(tokens[1] == .op("+"))
        #expect(tokens[3] == .op("-"))
        #expect(tokens[5] == .op("*"))
        #expect(tokens[7] == .op("/"))
    }

    @Test("Tokenizes negative number at start")
    func tokenizeNegativeNumber() {
        var tokenizer = DQLTokenizer("-5")
        let tokens = tokenizer.tokenize()
        #expect(tokens[0] == .number(-5))
    }

    @Test("Tokenizes minus as operator after identifier")
    func tokenizeMinusAfterIdent() {
        var tokenizer = DQLTokenizer("rating - 1")
        let tokens = tokenizer.tokenize()
        #expect(tokens[0] == .identifier("rating"))
        #expect(tokens[1] == .op("-"))
        #expect(tokens[2] == .number(1))
    }

    // MARK: - Parser: Query types

    @Test("Parses TABLE query type")
    func parseTableType() throws {
        let query = try DQLParser.parse("TABLE rating FROM \"Books\"")
        #expect(query.type == .table)
        #expect(query.fields.count == 1)
        #expect(query.fields[0].name == "rating")
    }

    @Test("Parses LIST query type")
    func parseListType() throws {
        let query = try DQLParser.parse("LIST FROM \"Projects\"")
        #expect(query.type == .list)
        #expect(query.fields.isEmpty)
    }

    @Test("Parses TASK query type")
    func parseTaskType() throws {
        let query = try DQLParser.parse("TASK FROM \"Work\"")
        #expect(query.type == .task)
    }

    // MARK: - Parser: Fields

    @Test("Parses multiple TABLE columns")
    func parseMultipleFields() throws {
        let query = try DQLParser.parse("TABLE rating, author, genre FROM \"Books\"")
        #expect(query.fields.count == 3)
        #expect(query.fields[0].name == "rating")
        #expect(query.fields[1].name == "author")
        #expect(query.fields[2].name == "genre")
    }

    @Test("Parses field with AS alias")
    func parseFieldAlias() throws {
        let query = try DQLParser.parse("TABLE rating AS Score FROM \"Books\"")
        #expect(query.fields[0].alias == "Score")
        #expect(query.fields[0].name == "Score")
    }

    @Test("Parses WITHOUT ID modifier")
    func parseWithoutId() throws {
        let query = try DQLParser.parse("TABLE WITHOUT ID rating FROM \"Books\"")
        #expect(query.withoutId == true)
        #expect(query.fields.count == 1)
    }

    // MARK: - Parser: FROM clause

    @Test("Parses FROM folder")
    func parseFromFolder() throws {
        let query = try DQLParser.parse("TABLE rating FROM \"Books\"")
        if case .folder(let name) = query.source {
            #expect(name == "Books")
        } else {
            #expect(Bool(false), "Expected folder source")
        }
    }

    @Test("Parses FROM #tag")
    func parseFromTag() throws {
        let query = try DQLParser.parse("LIST FROM #books")
        if case .tag(let tag) = query.source {
            #expect(tag == "books")
        } else {
            #expect(Bool(false), "Expected tag source")
        }
    }

    // MARK: - Parser: WHERE clause

    @Test("Parses simple WHERE comparison")
    func parseWhereComparison() throws {
        let query = try DQLParser.parse("TABLE rating FROM \"Books\" WHERE rating > 7")
        #expect(query.filter != nil)
        if case .comparison(let left, let op, let right) = query.filter {
            if case .identifier(let name) = left { #expect(name == "rating") }
            #expect(op == .greaterThan)
            if case .numberLiteral(let n) = right { #expect(n == 7) }
        }
    }

    @Test("Parses WHERE with string comparison")
    func parseWhereString() throws {
        let query = try DQLParser.parse("TABLE author FROM \"Books\" WHERE author = \"Tolkien\"")
        #expect(query.filter != nil)
    }

    @Test("Parses WHERE with AND")
    func parseWhereAnd() throws {
        let query = try DQLParser.parse("TABLE rating FROM \"Books\" WHERE rating > 5 AND rating < 10")
        if case .logicalAnd = query.filter {
            // pass
        } else {
            #expect(Bool(false), "Expected AND expression")
        }
    }

    // MARK: - Parser: SORT clause

    @Test("Parses SORT DESC")
    func parseSortDesc() throws {
        let query = try DQLParser.parse("TABLE rating FROM \"Books\" SORT rating DESC")
        #expect(query.sortClauses.count == 1)
        #expect(query.sortClauses[0].ascending == false)
    }

    @Test("Parses SORT ASC (default)")
    func parseSortAsc() throws {
        let query = try DQLParser.parse("TABLE rating FROM \"Books\" SORT rating ASC")
        #expect(query.sortClauses[0].ascending == true)
    }

    // MARK: - Parser: LIMIT clause

    @Test("Parses LIMIT")
    func parseLimit() throws {
        let query = try DQLParser.parse("TABLE rating FROM \"Books\" LIMIT 10")
        #expect(query.limit == 10)
    }

    // MARK: - Parser: Complex queries

    @Test("Parses full complex query")
    func parseComplexQuery() throws {
        let query = try DQLParser.parse("""
        TABLE rating, author FROM "Books" WHERE rating > 7 SORT rating DESC LIMIT 5
        """)
        #expect(query.type == .table)
        #expect(query.fields.count == 2)
        #expect(query.filter != nil)
        #expect(query.sortClauses.count == 1)
        #expect(query.limit == 5)
    }

    @Test("Parses file.name dot access")
    func parseDotAccess() throws {
        let query = try DQLParser.parse("TABLE file.name FROM \"Notes\"")
        #expect(query.fields.count == 1)
        if case .dotAccess(.identifier("file"), "name") = query.fields[0].expression {
            // pass
        } else {
            #expect(Bool(false), "Expected dot access expression")
        }
    }

    @Test("Parses LIST with expression")
    func parseListWithExpression() throws {
        let query = try DQLParser.parse("LIST rating FROM \"Books\"")
        #expect(query.type == .list)
        #expect(query.fields.count == 1)
        #expect(query.fields[0].name == "rating")
    }

    // MARK: - Parser: New features

    @Test("Parses date() function as date literal")
    func parseDateLiteral() throws {
        let query = try DQLParser.parse("TABLE date FROM \"Notes\" WHERE date > date(\"2024-01-01\")")
        #expect(query.filter != nil)
        if case .comparison(_, _, let right) = query.filter {
            if case .dateLiteral(let d) = right {
                #expect(d == "2024-01-01")
            } else {
                #expect(Bool(false), "Expected date literal, got \(right)")
            }
        }
    }

    @Test("Parses arithmetic expressions")
    func parseArithmetic() throws {
        let query = try DQLParser.parse("TABLE rating + 1 AS adjusted FROM \"Books\"")
        #expect(query.fields.count == 1)
        if case .arithmetic(_, let op, _) = query.fields[0].expression {
            #expect(op == .add)
        } else {
            #expect(Bool(false), "Expected arithmetic expression")
        }
    }

    @Test("Parses subtraction expression")
    func parseSubtraction() throws {
        let query = try DQLParser.parse("TABLE rating - 1 FROM \"Books\"")
        if case .arithmetic(let left, let op, let right) = query.fields[0].expression {
            #expect(op == .subtract)
            if case .identifier(let name) = left { #expect(name == "rating") }
            if case .numberLiteral(let n) = right { #expect(n == 1) }
        } else {
            #expect(Bool(false), "Expected arithmetic expression")
        }
    }

    @Test("Parses multiplication precedence")
    func parsePrecedence() throws {
        // a + b * c should be a + (b * c)
        let query = try DQLParser.parse("TABLE a + b * c FROM \"X\"")
        if case .arithmetic(_, let op, let right) = query.fields[0].expression {
            #expect(op == .add)
            if case .arithmetic(_, let innerOp, _) = right {
                #expect(innerOp == .multiply)
            } else {
                #expect(Bool(false), "Expected multiplication in right operand")
            }
        } else {
            #expect(Bool(false), "Expected addition at top level")
        }
    }

    @Test("Parses GROUP BY clause")
    func parseGroupBy() throws {
        let query = try DQLParser.parse("TABLE rating FROM \"Books\" GROUP BY genre")
        #expect(query.groupBy != nil)
        #expect(query.groupBy?.name == "genre")
    }

    @Test("Parses FLATTEN clause")
    func parseFlatten() throws {
        let query = try DQLParser.parse("TABLE tags FROM \"Notes\" FLATTEN tags")
        #expect(query.flatten != nil)
        #expect(query.flatten?.name == "tags")
    }

    @Test("Parses function call: default()")
    func parseDefaultFunction() throws {
        let query = try DQLParser.parse("TABLE default(rating, 0) AS rating FROM \"Books\"")
        #expect(query.fields.count == 1)
        if case .functionCall(let name, let args) = query.fields[0].expression {
            #expect(name == "default")
            #expect(args.count == 2)
        } else {
            #expect(Bool(false), "Expected function call")
        }
    }

    @Test("Parses contains() function syntax")
    func parseContainsFunction() throws {
        let query = try DQLParser.parse("LIST FROM #books WHERE contains(tags, \"fiction\")")
        #expect(query.filter != nil)
        if case .functionCall(let name, let args) = query.filter {
            #expect(name == "contains")
            #expect(args.count == 2)
        } else {
            #expect(Bool(false), "Expected contains function call")
        }
    }

    @Test("Parses contains keyword operator syntax")
    func parseContainsKeyword() throws {
        let query = try DQLParser.parse("LIST FROM #books WHERE tags CONTAINS \"fiction\"")
        #expect(query.filter != nil)
        if case .functionCall(let name, _) = query.filter {
            #expect(name == "contains")
        } else {
            #expect(Bool(false), "Expected contains function call")
        }
    }

    @Test("Parses NULL keyword")
    func parseNull() throws {
        let query = try DQLParser.parse("TABLE rating FROM \"Books\" WHERE rating != NULL")
        #expect(query.filter != nil)
    }

    @Test("Parses nested dot access: file.tags")
    func parseFileTags() throws {
        let query = try DQLParser.parse("TABLE file.tags FROM \"Notes\"")
        if case .dotAccess(.identifier("file"), "tags") = query.fields[0].expression {
            // pass
        } else {
            #expect(Bool(false), "Expected file.tags dot access")
        }
    }
}
