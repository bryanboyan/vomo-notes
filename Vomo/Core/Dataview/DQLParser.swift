import Foundation

// MARK: - Tokenizer

struct DQLTokenizer {
    private let input: String
    private var position: String.Index

    init(_ input: String) {
        self.input = input
        self.position = input.startIndex
    }

    mutating func tokenize() -> [DQLToken] {
        var tokens: [DQLToken] = []
        while position < input.endIndex {
            skipWhitespace()
            guard position < input.endIndex else { break }

            let ch = input[position]

            // String literals
            if ch == "\"" {
                tokens.append(readString())
                continue
            }

            // Numbers (only treat leading - as negative if preceded by operator/keyword/start)
            if ch.isNumber {
                tokens.append(readNumber())
                continue
            }
            if ch == "-" && peekNext()?.isNumber == true {
                // Only treat as negative number if previous token is an operator, keyword, comma, or paren
                let canBeNegative: Bool
                if let last = tokens.last {
                    switch last {
                    case .op, .keyword, .comma, .leftParen: canBeNegative = true
                    default: canBeNegative = false
                    }
                } else {
                    canBeNegative = true // start of input
                }
                if canBeNegative {
                    tokens.append(readNumber())
                    continue
                }
            }

            // Two-character operators
            if ch == "!" && peekNext() == "=" {
                advance(); advance()
                tokens.append(.op("!="))
                continue
            }
            if ch == "<" && peekNext() == "=" {
                advance(); advance()
                tokens.append(.op("<="))
                continue
            }
            if ch == ">" && peekNext() == "=" {
                advance(); advance()
                tokens.append(.op(">="))
                continue
            }

            // Single-character tokens
            switch ch {
            case ",": advance(); tokens.append(.comma)
            case ".": advance(); tokens.append(.dot)
            case "(": advance(); tokens.append(.leftParen)
            case ")": advance(); tokens.append(.rightParen)
            case "[": advance(); tokens.append(.leftBracket)
            case "]": advance(); tokens.append(.rightBracket)
            case "#": advance(); tokens.append(.hash)
            case "=": advance(); tokens.append(.op("="))
            case "<": advance(); tokens.append(.op("<"))
            case ">": advance(); tokens.append(.op(">"))
            case "+": advance(); tokens.append(.op("+"))
            case "-": advance(); tokens.append(.op("-"))
            case "*": advance(); tokens.append(.op("*"))
            case "/": advance(); tokens.append(.op("/"))
            default:
                if ch.isLetter || ch == "_" {
                    tokens.append(readIdentifierOrKeyword())
                } else {
                    // Skip unknown characters
                    advance()
                }
            }
        }
        tokens.append(.eof)
        return tokens
    }

    private mutating func skipWhitespace() {
        while position < input.endIndex && input[position].isWhitespace {
            advance()
        }
    }

    private mutating func readString() -> DQLToken {
        advance() // skip opening quote
        var result = ""
        while position < input.endIndex && input[position] != "\"" {
            if input[position] == "\\" && peekNext() == "\"" {
                advance()
            }
            result.append(input[position])
            advance()
        }
        if position < input.endIndex { advance() } // skip closing quote
        return .string(result)
    }

    private mutating func readNumber() -> DQLToken {
        var numStr = ""
        if input[position] == "-" {
            numStr.append("-")
            advance()
        }
        while position < input.endIndex && (input[position].isNumber || input[position] == ".") {
            numStr.append(input[position])
            advance()
        }
        return .number(Double(numStr) ?? 0)
    }

    private mutating func readIdentifierOrKeyword() -> DQLToken {
        var ident = ""
        while position < input.endIndex && (input[position].isLetter || input[position].isNumber || input[position] == "_" || input[position] == "-") {
            ident.append(input[position])
            advance()
        }
        // Check if it's a keyword
        if let kw = DQLKeyword(rawValue: ident.uppercased()) {
            return .keyword(kw)
        }
        return .identifier(ident)
    }

    private mutating func advance() {
        position = input.index(after: position)
    }

    private func peekNext() -> Character? {
        let next = input.index(after: position)
        guard next < input.endIndex else { return nil }
        return input[next]
    }
}

// MARK: - Parser

struct DQLParser {
    private var tokens: [DQLToken]
    private var pos: Int = 0

    init(tokens: [DQLToken]) {
        self.tokens = tokens
    }

    /// Parse a DQL query string into an AST
    static func parse(_ query: String) throws -> DQLQuery {
        var tokenizer = DQLTokenizer(query)
        let tokens = tokenizer.tokenize()
        var parser = DQLParser(tokens: tokens)
        return try parser.parseQuery()
    }

    // MARK: - Query parsing

    private mutating func parseQuery() throws -> DQLQuery {
        let type = try parseQueryType()

        var withoutId = false
        // Check for WITHOUT ID
        if peek() == .keyword(.without) {
            advance()
            if peek() == .keyword(.id) {
                advance()
                withoutId = true
            }
        }

        // Parse fields (TABLE columns, LIST expression)
        var fields: [DQLField] = []
        if type == .table {
            fields = try parseFieldList()
        } else if type == .list {
            // LIST may have an optional expression
            if !isClauseKeyword(peek()) && peek() != .eof {
                let expr = try parseExpression()
                let alias = try parseOptionalAlias()
                fields = [DQLField(expression: expr, alias: alias)]
            }
        }

        // Parse clauses
        var source: DQLSource?
        var filter: DQLExpression?
        var sortClauses: [DQLSort] = []
        var limit: Int?
        var groupBy: DQLField?
        var flatten: DQLField?

        while peek() != .eof {
            switch peek() {
            case .keyword(.from):
                advance()
                source = try parseSource()
            case .keyword(.where):
                advance()
                filter = try parseExpression()
            case .keyword(.sort):
                advance()
                sortClauses = try parseSortClauses()
            case .keyword(.limit):
                advance()
                limit = try parseLimitValue()
            case .keyword(.group):
                advance()
                try expect(.keyword(.by))
                let expr = try parseExpression()
                let alias = try parseOptionalAlias()
                groupBy = DQLField(expression: expr, alias: alias)
            case .keyword(.flatten):
                advance()
                let expr = try parseExpression()
                let alias = try parseOptionalAlias()
                flatten = DQLField(expression: expr, alias: alias)
            default:
                advance() // skip unknown
            }
        }

        return DQLQuery(
            type: type,
            fields: fields,
            source: source,
            filter: filter,
            sortClauses: sortClauses,
            limit: limit,
            withoutId: withoutId,
            groupBy: groupBy,
            flatten: flatten
        )
    }

    private mutating func parseQueryType() throws -> DQLQueryType {
        guard case .keyword(let kw) = peek() else {
            throw DQLParseError.expectedQueryType
        }
        advance()
        switch kw {
        case .table: return .table
        case .list: return .list
        case .task: return .task
        case .calendar: return .calendar
        default: throw DQLParseError.expectedQueryType
        }
    }

    private mutating func parseFieldList() throws -> [DQLField] {
        var fields: [DQLField] = []
        // Stop at clause keywords or EOF
        guard !isClauseKeyword(peek()) && peek() != .eof else { return fields }

        let expr = try parseExpression()
        let alias = try parseOptionalAlias()
        fields.append(DQLField(expression: expr, alias: alias))

        while peek() == .comma {
            advance() // skip comma
            let expr = try parseExpression()
            let alias = try parseOptionalAlias()
            fields.append(DQLField(expression: expr, alias: alias))
        }

        return fields
    }

    private mutating func parseSource() throws -> DQLSource {
        // FROM "FolderName"
        if case .string(let folder) = peek() {
            advance()
            return .folder(folder)
        }
        // FROM #tag
        if peek() == .hash {
            advance()
            guard case .identifier(let tag) = peek() else {
                throw DQLParseError.expectedIdentifier
            }
            advance()
            return .tag(tag)
        }
        // FROM outgoing([[page]])
        if case .keyword(.outgoing) = peek() {
            advance()
            try expect(.leftParen)
            let link = try parseLinkInSource()
            try expect(.rightParen)
            return .outgoing(link)
        }
        // FROM incoming([[page]])
        if case .keyword(.incoming) = peek() {
            advance()
            try expect(.leftParen)
            let link = try parseLinkInSource()
            try expect(.rightParen)
            return .incoming(link)
        }
        // FROM identifier (treat as folder)
        if case .identifier(let name) = peek() {
            advance()
            return .folder(name)
        }
        throw DQLParseError.expectedSource
    }

    private mutating func parseLinkInSource() throws -> String {
        // Expect [[ identifier ]]
        try expect(.leftBracket)
        try expect(.leftBracket)
        var name = ""
        while peek() != .rightBracket && peek() != .eof {
            if case .identifier(let ident) = peek() {
                if !name.isEmpty { name += " " }
                name += ident
            } else if case .string(let s) = peek() {
                name += s
            }
            advance()
        }
        try expect(.rightBracket)
        try expect(.rightBracket)
        return name
    }

    private mutating func parseSortClauses() throws -> [DQLSort] {
        var clauses: [DQLSort] = []
        let expr = try parseExpression()
        var ascending = true
        if case .keyword(.asc) = peek() { advance(); ascending = true }
        else if case .keyword(.desc) = peek() { advance(); ascending = false }
        clauses.append(DQLSort(field: expr, ascending: ascending))

        while peek() == .comma {
            advance()
            let expr = try parseExpression()
            var asc = true
            if case .keyword(.asc) = peek() { advance(); asc = true }
            else if case .keyword(.desc) = peek() { advance(); asc = false }
            clauses.append(DQLSort(field: expr, ascending: asc))
        }

        return clauses
    }

    private mutating func parseLimitValue() throws -> Int {
        guard case .number(let n) = peek() else {
            throw DQLParseError.expectedNumber
        }
        advance()
        return Int(n)
    }

    // MARK: - Expression parsing (precedence climbing)
    //
    // Precedence (low to high):
    //   OR → AND → NOT → comparison → addition (+,-) → multiplication (*,/) → unary → primary

    private mutating func parseExpression() throws -> DQLExpression {
        try parseOr()
    }

    private mutating func parseOr() throws -> DQLExpression {
        var left = try parseAnd()
        while case .keyword(.or) = peek() {
            advance()
            let right = try parseAnd()
            left = .logicalOr(left, right)
        }
        return left
    }

    private mutating func parseAnd() throws -> DQLExpression {
        var left = try parseNot()
        while case .keyword(.and) = peek() {
            advance()
            let right = try parseNot()
            left = .logicalAnd(left, right)
        }
        return left
    }

    private mutating func parseNot() throws -> DQLExpression {
        if case .keyword(.not) = peek() {
            advance()
            let expr = try parseComparison()
            return .logicalNot(expr)
        }
        return try parseComparison()
    }

    private mutating func parseComparison() throws -> DQLExpression {
        let left = try parseAddition()
        if case .op(let opStr) = peek(), let op = ComparisonOp(rawValue: opStr) {
            advance()
            let right = try parseAddition()
            return .comparison(left, op, right)
        }
        // Handle contains as a keyword-style operator: `field CONTAINS value`
        if case .keyword(.contains) = peek() {
            advance()
            let right = try parseAddition()
            return .functionCall("contains", [left, right])
        }
        return left
    }

    private mutating func parseAddition() throws -> DQLExpression {
        var left = try parseMultiplication()
        while case .op(let opStr) = peek(), (opStr == "+" || opStr == "-") {
            advance()
            let right = try parseMultiplication()
            let op: ArithmeticOp = opStr == "+" ? .add : .subtract
            left = .arithmetic(left, op, right)
        }
        return left
    }

    private mutating func parseMultiplication() throws -> DQLExpression {
        var left = try parseUnary()
        while case .op(let opStr) = peek(), (opStr == "*" || opStr == "/") {
            advance()
            let right = try parseUnary()
            let op: ArithmeticOp = opStr == "*" ? .multiply : .divide
            left = .arithmetic(left, op, right)
        }
        return left
    }

    private mutating func parseUnary() throws -> DQLExpression {
        // Unary minus: -expr
        if case .op("-") = peek() {
            advance()
            let expr = try parsePrimary()
            return .negation(expr)
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> DQLExpression {
        switch peek() {
        case .string(let s):
            advance()
            return .stringLiteral(s)
        case .number(let n):
            advance()
            return .numberLiteral(n)
        case .keyword(.true):
            advance()
            return .boolLiteral(true)
        case .keyword(.false):
            advance()
            return .boolLiteral(false)
        case .keyword(.null):
            advance()
            return .identifier("null")
        case .keyword(.contains):
            // contains(field, value) function syntax
            advance()
            try expect(.leftParen)
            let arg1 = try parseExpression()
            try expect(.comma)
            let arg2 = try parseExpression()
            try expect(.rightParen)
            return .functionCall("contains", [arg1, arg2])
        case .keyword(let kw) where isFunctionKeyword(kw):
            // Handle keywords that are also function names (e.g., date, list)
            let name = kw.rawValue.lowercased()
            advance()
            if peek() == .leftParen {
                advance()
                var args: [DQLExpression] = []
                if peek() != .rightParen {
                    args.append(try parseExpression())
                    while peek() == .comma {
                        advance()
                        args.append(try parseExpression())
                    }
                }
                try expect(.rightParen)
                // Special: date("...") → dateLiteral
                if name == "date" && args.count == 1, case .stringLiteral(let s) = args[0] {
                    return .dateLiteral(s)
                }
                return .functionCall(name, args)
            }
            // If not followed by (, treat as identifier
            return .identifier(name)
        case .leftParen:
            advance()
            let expr = try parseExpression()
            try expect(.rightParen)
            return expr
        case .identifier(let name):
            advance()
            // Check for dot access chain: file.name, file.mtime, etc.
            var result: DQLExpression = .identifier(name)
            while peek() == .dot {
                advance()
                if case .identifier(let field) = peek() {
                    advance()
                    result = .dotAccess(result, field)
                } else if case .keyword(let kw) = peek() {
                    advance()
                    result = .dotAccess(result, kw.rawValue.lowercased())
                } else {
                    break
                }
            }
            // Check for function call: name(...) — only if result is still a simple identifier
            if case .identifier(let funcName) = result, peek() == .leftParen {
                advance()
                var args: [DQLExpression] = []
                if peek() != .rightParen {
                    args.append(try parseExpression())
                    while peek() == .comma {
                        advance()
                        args.append(try parseExpression())
                    }
                }
                try expect(.rightParen)
                // Special: date("...") → dateLiteral
                if funcName == "date" && args.count == 1, case .stringLiteral(let s) = args[0] {
                    return .dateLiteral(s)
                }
                return .functionCall(funcName, args)
            }
            return result
        default:
            throw DQLParseError.unexpectedToken(peek())
        }
    }

    private func isFunctionKeyword(_ kw: DQLKeyword) -> Bool {
        switch kw {
        case .date, .list, .default: return true
        default: return false
        }
    }

    private mutating func parseOptionalAlias() throws -> String? {
        if case .keyword(.as) = peek() {
            advance()
            if case .identifier(let name) = peek() {
                advance()
                return name
            }
            if case .string(let name) = peek() {
                advance()
                return name
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func peek() -> DQLToken {
        guard pos < tokens.count else { return .eof }
        return tokens[pos]
    }

    private mutating func advance() {
        pos += 1
    }

    private mutating func expect(_ expected: DQLToken) throws {
        guard peek() == expected else {
            throw DQLParseError.expected(expected, got: peek())
        }
        advance()
    }

    private func isClauseKeyword(_ token: DQLToken) -> Bool {
        switch token {
        case .keyword(.from), .keyword(.where), .keyword(.sort),
             .keyword(.limit), .keyword(.group), .keyword(.flatten):
            return true
        default:
            return false
        }
    }
}

// MARK: - Errors

enum DQLParseError: Error, LocalizedError {
    case expectedQueryType
    case expectedIdentifier
    case expectedNumber
    case expectedSource
    case unexpectedToken(DQLToken)
    case expected(DQLToken, got: DQLToken)

    var errorDescription: String? {
        switch self {
        case .expectedQueryType: return "Expected TABLE, LIST, TASK, or CALENDAR"
        case .expectedIdentifier: return "Expected identifier"
        case .expectedNumber: return "Expected number"
        case .expectedSource: return "Expected source (folder, #tag, or link)"
        case .unexpectedToken(let t): return "Unexpected token: \(t)"
        case .expected(let e, let g): return "Expected \(e), got \(g)"
        }
    }
}
