import Foundation

// MARK: - DQL Abstract Syntax Tree

/// The type of Dataview query
enum DQLQueryType: String {
    case table = "TABLE"
    case list = "LIST"
    case task = "TASK"
    case calendar = "CALENDAR"
}

/// A complete parsed DQL query
struct DQLQuery {
    let type: DQLQueryType
    let fields: [DQLField]         // TABLE columns or LIST expression
    let source: DQLSource?         // FROM clause
    let filter: DQLExpression?     // WHERE clause
    let sortClauses: [DQLSort]     // SORT clause
    let limit: Int?                // LIMIT clause
    let withoutId: Bool            // WITHOUT ID modifier
    let groupBy: DQLField?         // GROUP BY clause
    let flatten: DQLField?         // FLATTEN clause
}

/// A field reference (column in TABLE, or expression)
struct DQLField {
    let expression: DQLExpression
    let alias: String?             // AS rename

    var name: String {
        alias ?? expression.fieldName
    }
}

/// Source for FROM clause
enum DQLSource {
    case folder(String)                          // FROM "FolderName"
    case tag(String)                             // FROM #tag
    case outgoing(String)                        // FROM outgoing([[page]])
    case incoming(String)                        // FROM incoming([[page]])
}

/// Expressions in WHERE, field references, function calls
indirect enum DQLExpression {
    case identifier(String)                      // field name
    case dotAccess(DQLExpression, String)         // file.name, file.mtime
    case stringLiteral(String)                   // "string"
    case numberLiteral(Double)                   // 42, 3.14
    case boolLiteral(Bool)                       // true, false
    case dateLiteral(String)                     // date("2024-01-01")
    case comparison(DQLExpression, ComparisonOp, DQLExpression)
    case logicalAnd(DQLExpression, DQLExpression)
    case logicalOr(DQLExpression, DQLExpression)
    case logicalNot(DQLExpression)
    case functionCall(String, [DQLExpression])   // contains(), length(), etc.
    case arithmetic(DQLExpression, ArithmeticOp, DQLExpression) // +, -, *, /
    case listLiteral([DQLExpression])            // list(a, b, c)
    case negation(DQLExpression)                 // -expr (unary minus)

    /// Best-effort name for display
    var fieldName: String {
        switch self {
        case .identifier(let name): return name
        case .dotAccess(let base, let field):
            return "\(base.fieldName).\(field)"
        case .functionCall(let name, _): return name
        default: return "expr"
        }
    }
}

/// Arithmetic operators
enum ArithmeticOp: String {
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
}

enum ComparisonOp: String {
    case equal = "="
    case notEqual = "!="
    case lessThan = "<"
    case greaterThan = ">"
    case lessOrEqual = "<="
    case greaterOrEqual = ">="
}

/// Sort clause
struct DQLSort {
    let field: DQLExpression
    let ascending: Bool
}

// MARK: - Query Result

/// Result of executing a DQL query
struct DataviewResult {
    let queryType: DQLQueryType
    let columns: [String]          // column headers for TABLE
    let rows: [DataviewRow]        // result rows
}

struct DataviewRow: Identifiable {
    let id: String                 // document path
    let title: String              // document title
    let values: [DataviewValue]    // column values
}

enum DataviewValue {
    case text(String)
    case number(Double)
    case date(String)
    case bool(Bool)
    case link(String, String)      // (path, display)
    case list([String])
    case null

    var displayString: String {
        switch self {
        case .text(let s): return s
        case .number(let n):
            if n == n.rounded() && n < 1e15 {
                return String(Int(n))
            }
            return String(n)
        case .date(let d): return d
        case .bool(let b): return b ? "true" : "false"
        case .link(_, let display): return display
        case .list(let items): return items.joined(separator: ", ")
        case .null: return "-"
        }
    }
}

// MARK: - Tokens

enum DQLToken: Equatable {
    case keyword(DQLKeyword)
    case identifier(String)
    case string(String)
    case number(Double)
    case op(String)            // =, !=, <, >, <=, >=
    case comma
    case dot
    case leftParen
    case rightParen
    case leftBracket
    case rightBracket
    case hash                  // # for tags
    case eof
}

enum DQLKeyword: String, CaseIterable {
    case table = "TABLE"
    case list = "LIST"
    case task = "TASK"
    case calendar = "CALENDAR"
    case from = "FROM"
    case `where` = "WHERE"
    case sort = "SORT"
    case group = "GROUP"
    case by = "BY"
    case flatten = "FLATTEN"
    case limit = "LIMIT"
    case without = "WITHOUT"
    case id = "ID"
    case `as` = "AS"
    case and = "AND"
    case or = "OR"
    case not = "NOT"
    case asc = "ASC"
    case desc = "DESC"
    case `true` = "TRUE"
    case `false` = "FALSE"
    case contains = "CONTAINS"
    case outgoing = "OUTGOING"
    case incoming = "INCOMING"
    case date = "DATE"
    case `default` = "DEFAULT"
    case null = "NULL"
}
