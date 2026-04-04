import Foundation
import GRDB

/// Translates a DQL AST into SQL and executes it against the database
struct QueryExecutor {
    let db: DataviewDatabase

    func execute(_ query: DQLQuery) throws -> DataviewResult {
        let baseResult: DataviewResult
        switch query.type {
        case .table:
            baseResult = try executeTable(query)
        case .list:
            baseResult = try executeList(query)
        case .task:
            baseResult = try executeTask(query)
        case .calendar:
            baseResult = try executeCalendar(query)
        }

        // Post-process: GROUP BY (done in Swift, not SQL, for flexibility)
        if let groupBy = query.groupBy {
            return applyGroupBy(baseResult, groupBy: groupBy, query: query)
        }

        // Post-process: FLATTEN
        if let flatten = query.flatten {
            return applyFlatten(baseResult, flatten: flatten, query: query)
        }

        return baseResult
    }

    // MARK: - TABLE query

    private func executeTable(_ query: DQLQuery) throws -> DataviewResult {
        var context = SQLBuildContext()

        // SELECT clause
        var selectParts = ["d.path", "d.title", "d.folderPath", "d.modifiedDate", "d.fileSize"]
        let fieldNames = query.fields.map { $0.name }

        for (i, field) in query.fields.enumerated() {
            let alias = "p\(i)"
            let resolved = resolveFieldSQL(field.expression, tableAlias: alias, context: &context)
            if resolved.needsJoin {
                let fieldKey = resolvePropertyKey(field.expression)
                context.joins.append(
                    "LEFT JOIN properties \(alias) ON \(alias).documentPath = d.path AND \(alias).key = '\(fieldKey.sqlEscaped)'"
                )
            }
            selectParts.append("\(resolved.sql) AS \(sanitizeAlias(field.name))")
        }

        // If GROUP BY field is not in the SELECT list, add it as a hidden field
        if let groupBy = query.groupBy, !fieldNames.contains(groupBy.name) {
            let alias = "pgb"
            let resolved = resolveFieldSQL(groupBy.expression, tableAlias: alias, context: &context)
            if resolved.needsJoin {
                let fieldKey = resolvePropertyKey(groupBy.expression)
                context.joins.append(
                    "LEFT JOIN properties \(alias) ON \(alias).documentPath = d.path AND \(alias).key = '\(fieldKey.sqlEscaped)'"
                )
            }
            selectParts.append("\(resolved.sql) AS __groupby__")
        }

        // FROM clause
        var whereClauses = buildSourceWhere(query.source)

        // WHERE clause
        if let filter = query.filter {
            let filterSQL = buildWhereSQL(filter, context: &context)
            whereClauses.append(filterSQL)
        }

        // Build SQL
        var sql = "SELECT DISTINCT \(selectParts.joined(separator: ", ")) FROM documents d"

        // Add joins
        for join in context.joins {
            sql += " \(join)"
        }

        // WHERE
        if !whereClauses.isEmpty {
            sql += " WHERE \(whereClauses.joined(separator: " AND "))"
        }

        // SORT
        if !query.sortClauses.isEmpty {
            let orderParts = query.sortClauses.map { sort -> String in
                let sortSQL = buildSortSQL(sort, queryFields: query.fields, context: &context)
                return "\(sortSQL) \(sort.ascending ? "ASC" : "DESC")"
            }
            sql += " ORDER BY \(orderParts.joined(separator: ", "))"
        }

        // LIMIT
        if let limit = query.limit {
            sql += " LIMIT \(limit)"
        }

        // Execute
        let rows = try db.executeQuery(sql: sql)

        // Build result
        var columns = query.withoutId ? [] : ["File"]
        columns += fieldNames

        let resultRows = rows.map { row -> DataviewRow in
            let path = (row["path"] as? String) ?? ""
            let title = (row["title"] as? String) ?? ""

            var values: [DataviewValue] = []
            for field in query.fields {
                let alias = sanitizeAlias(field.name)
                // Strip outer quotes for GRDB column lookup — SQL AS "x" stores as x
                let colName = alias.hasPrefix("\"") && alias.hasSuffix("\"")
                    ? String(alias.dropFirst().dropLast())
                    : alias
                let col = Column(colName)
                let val: DatabaseValue = row[col]
                values.append(rowValueToDataview(val))
            }

            // If GROUP BY field was added as hidden column, append it at the end
            if query.groupBy != nil && !fieldNames.contains(query.groupBy!.name) {
                let gbVal: DatabaseValue = row[Column("__groupby__")]
                values.append(rowValueToDataview(gbVal))
            }

            return DataviewRow(id: path, title: title, values: values)
        }

        return DataviewResult(queryType: .table, columns: columns, rows: resultRows)
    }

    // MARK: - LIST query

    private func executeList(_ query: DQLQuery) throws -> DataviewResult {
        var context = SQLBuildContext()
        var selectParts = ["d.path", "d.title", "d.folderPath", "d.modifiedDate", "d.fileSize"]

        // If LIST has a field expression, add it
        if let field = query.fields.first {
            let alias = "p0"
            let resolved = resolveFieldSQL(field.expression, tableAlias: alias, context: &context)
            if resolved.needsJoin {
                let fieldKey = resolvePropertyKey(field.expression)
                context.joins.append(
                    "LEFT JOIN properties \(alias) ON \(alias).documentPath = d.path AND \(alias).key = '\(fieldKey.sqlEscaped)'"
                )
            }
            selectParts.append("\(resolved.sql) AS value")
        }

        var whereClauses = buildSourceWhere(query.source)
        if let filter = query.filter {
            let filterSQL = buildWhereSQL(filter, context: &context)
            whereClauses.append(filterSQL)
        }

        var sql = "SELECT DISTINCT \(selectParts.joined(separator: ", ")) FROM documents d"
        for join in context.joins { sql += " \(join)" }
        if !whereClauses.isEmpty { sql += " WHERE \(whereClauses.joined(separator: " AND "))" }

        if !query.sortClauses.isEmpty {
            let orderParts = query.sortClauses.map { sort -> String in
                let sortSQL = buildSortSQL(sort, queryFields: query.fields, context: &context)
                return "\(sortSQL) \(sort.ascending ? "ASC" : "DESC")"
            }
            sql += " ORDER BY \(orderParts.joined(separator: ", "))"
        }

        if let limit = query.limit { sql += " LIMIT \(limit)" }

        let rows = try db.executeQuery(sql: sql)
        let resultRows = rows.map { row -> DataviewRow in
            let path = (row["path"] as? String) ?? ""
            let title = (row["title"] as? String) ?? ""
            var values: [DataviewValue] = []
            if query.fields.first != nil {
                let col = Column("value")
                let val: DatabaseValue = row[col]
                values.append(rowValueToDataview(val))
            }
            return DataviewRow(id: path, title: title, values: values)
        }

        return DataviewResult(queryType: .list, columns: [], rows: resultRows)
    }

    // MARK: - TASK query

    private func executeTask(_ query: DQLQuery) throws -> DataviewResult {
        var whereClauses: [String] = []

        // Source filtering
        if let source = query.source {
            switch source {
            case .folder(let folder):
                whereClauses.append("(d.folderPath LIKE '\(folder.sqlEscaped)/%' OR d.folderPath = '\(folder.sqlEscaped)')")
            case .tag(let tag):
                whereClauses.append("EXISTS (SELECT 1 FROM tags t WHERE t.documentPath = d.path AND t.tag = '\(tag.sqlEscaped)')")
            default: break
            }
        }

        // WHERE on task properties
        if let filter = query.filter {
            let filterSQL = buildTaskWhereSQL(filter)
            whereClauses.append(filterSQL)
        }

        var sql = "SELECT tk.id, tk.documentPath, tk.text, tk.completed, tk.lineNumber, d.title FROM tasks tk JOIN documents d ON d.path = tk.documentPath"
        if !whereClauses.isEmpty { sql += " WHERE \(whereClauses.joined(separator: " AND "))" }
        sql += " ORDER BY d.title, tk.lineNumber"
        if let limit = query.limit { sql += " LIMIT \(limit)" }

        let rows = try db.executeQuery(sql: sql)
        let resultRows = rows.map { row -> DataviewRow in
            let path = (row["documentPath"] as? String) ?? ""
            let title = (row["title"] as? String) ?? ""
            let text = (row["text"] as? String) ?? ""
            let completed = (row["completed"] as? Int64 ?? 0) != 0
            return DataviewRow(
                id: "\(path):\(row["id"] ?? 0)",
                title: title,
                values: [.text(text), .bool(completed)]
            )
        }

        return DataviewResult(queryType: .task, columns: ["Task", "Done"], rows: resultRows)
    }

    // MARK: - CALENDAR query

    private func executeCalendar(_ query: DQLQuery) throws -> DataviewResult {
        // CALENDAR expects a date field to group by
        let dateField = query.fields.first?.expression.fieldName ?? "date"
        var context = SQLBuildContext()

        var selectParts = ["d.path", "d.title"]
        let alias = "pdate"
        context.joins.append(
            "LEFT JOIN properties \(alias) ON \(alias).documentPath = d.path AND \(alias).key = '\(dateField.sqlEscaped)'"
        )
        selectParts.append("COALESCE(\(alias).valueDate, \(alias).valueText) AS calendarDate")

        var whereClauses = buildSourceWhere(query.source)
        if let filter = query.filter {
            let filterSQL = buildWhereSQL(filter, context: &context)
            whereClauses.append(filterSQL)
        }

        var sql = "SELECT \(selectParts.joined(separator: ", ")) FROM documents d"
        for join in context.joins { sql += " \(join)" }
        if !whereClauses.isEmpty { sql += " WHERE \(whereClauses.joined(separator: " AND "))" }
        sql += " ORDER BY calendarDate"

        let rows = try db.executeQuery(sql: sql)
        let resultRows = rows.map { row -> DataviewRow in
            let path = (row["path"] as? String) ?? ""
            let title = (row["title"] as? String) ?? ""
            let dateVal = (row["calendarDate"] as? String) ?? ""
            return DataviewRow(id: path, title: title, values: [.date(dateVal)])
        }

        return DataviewResult(queryType: .calendar, columns: ["date"], rows: resultRows)
    }

    // MARK: - GROUP BY (post-process)

    private func applyGroupBy(_ result: DataviewResult, groupBy: DQLField, query: DQLQuery) -> DataviewResult {
        let groupKeyName = groupBy.name

        // Find which column index the group key is in
        let groupKeyIndex: Int?
        if let idx = query.fields.firstIndex(where: { $0.name == groupKeyName }) {
            groupKeyIndex = idx
        } else {
            groupKeyIndex = nil
        }

        // Hidden group-by value is appended at the end of values when not in query fields
        let hiddenGroupByIndex: Int? = groupKeyIndex == nil ? query.fields.count : nil

        // Group rows by the group key value
        var groups: [(key: String, rows: [DataviewRow])] = []
        var groupOrder: [String] = []
        var groupMap: [String: [DataviewRow]] = [:]

        for row in result.rows {
            let keyValue: String
            if let idx = groupKeyIndex, idx < row.values.count {
                keyValue = row.values[idx].displayString
            } else if let idx = hiddenGroupByIndex, idx < row.values.count {
                keyValue = row.values[idx].displayString
            } else {
                keyValue = row.title
            }

            if groupMap[keyValue] == nil {
                groupOrder.append(keyValue)
            }
            groupMap[keyValue, default: []].append(row)
        }

        for key in groupOrder {
            if let rows = groupMap[key] {
                groups.append((key: key, rows: rows))
            }
        }

        // Flatten into rows with group headers
        var flatRows: [DataviewRow] = []
        var columns = result.columns
        if !columns.contains(groupKeyName) {
            columns.insert(groupKeyName, at: columns.isEmpty ? 0 : 1)
        }

        for group in groups {
            for row in group.rows {
                // Strip hidden group-by value if present, then insert group key
                var values = row.values
                if hiddenGroupByIndex != nil && values.count > query.fields.count {
                    values.removeLast()
                }
                if groupKeyIndex == nil {
                    values.insert(.text(group.key), at: 0)
                }
                flatRows.append(DataviewRow(
                    id: "\(group.key):\(row.id)",
                    title: row.title,
                    values: values
                ))
            }
        }

        return DataviewResult(queryType: result.queryType, columns: columns, rows: flatRows)
    }

    // MARK: - FLATTEN (post-process)

    private func applyFlatten(_ result: DataviewResult, flatten: DQLField, query: DQLQuery) -> DataviewResult {
        let flattenFieldName = flatten.name

        // Find which column index to flatten
        let flattenIndex: Int?
        if let idx = query.fields.firstIndex(where: { $0.name == flattenFieldName }) {
            flattenIndex = idx
        } else {
            flattenIndex = nil
        }

        guard let idx = flattenIndex else { return result }

        var flatRows: [DataviewRow] = []
        for row in result.rows {
            if idx < row.values.count, case .list(let items) = row.values[idx] {
                // Expand each list item into its own row
                for (i, item) in items.enumerated() {
                    var values = row.values
                    values[idx] = .text(item)
                    flatRows.append(DataviewRow(
                        id: "\(row.id):\(i)",
                        title: row.title,
                        values: values
                    ))
                }
            } else if idx < row.values.count, case .text(let s) = row.values[idx], s.contains(", ") {
                // Comma-separated values that look like lists
                let items = s.components(separatedBy: ", ")
                for (i, item) in items.enumerated() {
                    var values = row.values
                    values[idx] = .text(item)
                    flatRows.append(DataviewRow(
                        id: "\(row.id):\(i)",
                        title: row.title,
                        values: values
                    ))
                }
            } else {
                flatRows.append(row)
            }
        }

        return DataviewResult(queryType: result.queryType, columns: result.columns, rows: flatRows)
    }

    // MARK: - SQL Building Helpers

    private func buildSourceWhere(_ source: DQLSource?) -> [String] {
        guard let source = source else { return [] }
        switch source {
        case .folder(let folder):
            return ["(d.folderPath LIKE '\(folder.sqlEscaped)/%' OR d.folderPath = '\(folder.sqlEscaped)')"]
        case .tag(let tag):
            return ["EXISTS (SELECT 1 FROM tags t WHERE t.documentPath = d.path AND t.tag = '\(tag.sqlEscaped)')"]
        case .outgoing(let page):
            return ["EXISTS (SELECT 1 FROM links l WHERE l.sourcePath = (SELECT path FROM documents WHERE title = '\(page.sqlEscaped)') AND l.targetResolved = d.path)"]
        case .incoming(let page):
            return ["EXISTS (SELECT 1 FROM links l WHERE l.sourcePath = d.path AND l.targetResolved = (SELECT path FROM documents WHERE title = '\(page.sqlEscaped)'))"]
        }
    }

    /// Resolve a field expression's property key for JOIN conditions
    private func resolvePropertyKey(_ expr: DQLExpression) -> String {
        switch expr {
        case .identifier(let name): return name
        case .dotAccess(_, let field): return field
        case .functionCall(_, let args) where !args.isEmpty:
            return resolvePropertyKey(args[0])
        default: return expr.fieldName
        }
    }

    private func resolveFieldSQL(_ expr: DQLExpression, tableAlias: String, context: inout SQLBuildContext) -> (sql: String, needsJoin: Bool) {
        switch expr {
        case .identifier(let name):
            if let column = implicitFieldColumn(name) {
                return (column, false)
            }
            if name == "null" {
                return ("NULL", false)
            }
            return ("COALESCE(\(tableAlias).valueDate, \(tableAlias).valueNumber, \(tableAlias).valueText)", true)

        case .dotAccess(.identifier("file"), let field):
            if let column = implicitFileField(field) {
                return (column, false)
            }
            // file.tags → subquery
            if field == "tags" {
                return ("(SELECT GROUP_CONCAT(tag, ', ') FROM tags WHERE documentPath = d.path)", false)
            }
            // file.outlinks → count
            if field == "outlinks" {
                return ("(SELECT COUNT(*) FROM links WHERE sourcePath = d.path)", false)
            }
            // file.inlinks → count
            if field == "inlinks" {
                return ("(SELECT COUNT(*) FROM links WHERE targetResolved = d.path)", false)
            }
            // file.tasks → count
            if field == "tasks" {
                return ("(SELECT COUNT(*) FROM tasks WHERE documentPath = d.path)", false)
            }
            // file.day → date portion of file path/name if it matches YYYY-MM-DD
            if field == "day" {
                return ("CASE WHEN d.title GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*' THEN SUBSTR(d.title, 1, 10) ELSE NULL END", false)
            }
            // file.ext → always md
            if field == "ext" {
                return ("'md'", false)
            }
            // file.link → the file path as a link
            if field == "link" {
                return ("'[[' || d.title || ']]'", false)
            }
            return ("NULL", false)

        case .dotAccess(let base, let field):
            // Generic dot access: property.subfield → just lookup the base property
            let baseKey = resolvePropertyKey(base)
            if let column = implicitFieldColumn(baseKey + "." + field) {
                return (column, false)
            }
            return ("COALESCE(\(tableAlias).valueDate, \(tableAlias).valueNumber, \(tableAlias).valueText)", true)

        case .functionCall(let name, let args):
            let argsSQL = args.map { expressionToSQL($0, context: &context) }
            return (buildFunctionSQL(name, args: argsSQL), false)

        case .arithmetic(let left, let op, let right):
            let leftSQL = expressionToSQL(left, context: &context)
            let rightSQL = expressionToSQL(right, context: &context)
            return ("(\(leftSQL) \(op.rawValue) \(rightSQL))", false)

        default:
            return ("NULL", false)
        }
    }

    private func buildSortSQL(_ sort: DQLSort, queryFields: [DQLField], context: inout SQLBuildContext) -> String {
        let field = sort.field.fieldName
        // Check if it's a joined field
        if let idx = queryFields.firstIndex(where: { $0.name == field }) {
            let alias = "p\(idx)"
            return "COALESCE(\(alias).valueDate, \(alias).valueNumber, \(alias).valueText)"
        }
        // file.* fields
        if let column = implicitFieldColumn(field) {
            return column
        }
        // Property subquery fallback
        return "(SELECT COALESCE(valueDate, valueNumber, valueText) FROM properties WHERE documentPath = d.path AND key = '\(field.sqlEscaped)' LIMIT 1)"
    }

    private func buildWhereSQL(_ expr: DQLExpression, context: inout SQLBuildContext) -> String {
        switch expr {
        case .comparison(let left, let op, let right):
            let leftSQL = expressionToSQL(left, context: &context)
            let rightSQL = expressionToSQL(right, context: &context)
            // Handle NULL comparisons
            if case .identifier("null") = right {
                return op == .equal ? "\(leftSQL) IS NULL" : "\(leftSQL) IS NOT NULL"
            }
            if case .identifier("null") = left {
                return op == .equal ? "\(rightSQL) IS NULL" : "\(rightSQL) IS NOT NULL"
            }
            return "\(leftSQL) \(op.rawValue) \(rightSQL)"

        case .logicalAnd(let left, let right):
            let leftSQL = buildWhereSQL(left, context: &context)
            let rightSQL = buildWhereSQL(right, context: &context)
            return "(\(leftSQL) AND \(rightSQL))"

        case .logicalOr(let left, let right):
            let leftSQL = buildWhereSQL(left, context: &context)
            let rightSQL = buildWhereSQL(right, context: &context)
            return "(\(leftSQL) OR \(rightSQL))"

        case .logicalNot(let inner):
            let innerSQL = buildWhereSQL(inner, context: &context)
            return "NOT (\(innerSQL))"

        case .functionCall("contains", let args) where args.count == 2:
            return buildContainsSQL(args[0], args[1], context: &context)

        case .functionCall(let name, let args):
            let argsSQL = args.map { expressionToSQL($0, context: &context) }
            return buildFunctionSQL(name, args: argsSQL)

        case .identifier(let name):
            // Bare identifier in WHERE (e.g., `WHERE completed`)
            return expressionToSQL(expr, context: &context)

        default:
            // Expression that evaluates to truthy
            let sql = expressionToSQL(expr, context: &context)
            if sql != "NULL" { return sql }
            return "1=1"
        }
    }

    /// Build SQL for contains() — handles both list membership and string containment
    private func buildContainsSQL(_ field: DQLExpression, _ value: DQLExpression, context: inout SQLBuildContext) -> String {
        let fieldName = field.fieldName
        let valueSQL = expressionToSQL(value, context: &context)

        // If field is file.tags, check tags table
        if fieldName == "tags", case .dotAccess(.identifier("file"), "tags") = field {
            return "EXISTS (SELECT 1 FROM tags WHERE documentPath = d.path AND tag = \(valueSQL))"
        }

        // Multi-strategy: check propertyValues (list items) OR string containment in properties
        return """
        (EXISTS (SELECT 1 FROM propertyValues pv WHERE pv.documentPath = d.path AND pv.key = '\(fieldName.sqlEscaped)' AND pv.valueText = \(valueSQL)) \
        OR EXISTS (SELECT 1 FROM properties pr WHERE pr.documentPath = d.path AND pr.key = '\(fieldName.sqlEscaped)' AND pr.valueText LIKE '%' || \(valueSQL) || '%') \
        OR EXISTS (SELECT 1 FROM tags WHERE documentPath = d.path AND tag = \(valueSQL)))
        """
    }

    private func buildTaskWhereSQL(_ expr: DQLExpression) -> String {
        switch expr {
        case .comparison(.identifier("completed"), let op, .boolLiteral(let val)):
            return "tk.completed \(op.rawValue) \(val ? 1 : 0)"
        case .comparison(.identifier("text"), _, .stringLiteral(let s)):
            return "tk.text LIKE '%\(s.sqlEscaped)%'"
        case .logicalNot(.identifier("completed")):
            return "tk.completed = 0"
        case .identifier("completed"):
            return "tk.completed = 1"
        case .logicalAnd(let left, let right):
            return "(\(buildTaskWhereSQL(left)) AND \(buildTaskWhereSQL(right)))"
        case .logicalOr(let left, let right):
            return "(\(buildTaskWhereSQL(left)) OR \(buildTaskWhereSQL(right)))"
        case .logicalNot(let inner):
            return "NOT (\(buildTaskWhereSQL(inner)))"
        default:
            return "1=1"
        }
    }

    private func expressionToSQL(_ expr: DQLExpression, context: inout SQLBuildContext) -> String {
        switch expr {
        case .identifier(let name):
            if name == "null" { return "NULL" }
            if let column = implicitFieldColumn(name) {
                return column
            }
            // Property lookup via subquery
            return "(SELECT COALESCE(valueDate, valueNumber, valueText) FROM properties WHERE documentPath = d.path AND key = '\(name.sqlEscaped)' LIMIT 1)"

        case .dotAccess(.identifier("file"), let field):
            if let column = implicitFileField(field) {
                return column
            }
            // Special file fields
            if field == "tags" {
                return "(SELECT GROUP_CONCAT(tag, ', ') FROM tags WHERE documentPath = d.path)"
            }
            if field == "outlinks" {
                return "(SELECT COUNT(*) FROM links WHERE sourcePath = d.path)"
            }
            if field == "inlinks" {
                return "(SELECT COUNT(*) FROM links WHERE targetResolved = d.path)"
            }
            if field == "tasks" {
                return "(SELECT COUNT(*) FROM tasks WHERE documentPath = d.path)"
            }
            if field == "day" {
                return "CASE WHEN d.title GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*' THEN SUBSTR(d.title, 1, 10) ELSE NULL END"
            }
            if field == "ext" { return "'md'" }
            if field == "link" { return "'[[' || d.title || ']]'" }
            return "NULL"

        case .dotAccess(let base, let field):
            // Generic property.subfield
            let baseKey = base.fieldName
            let fullKey = baseKey + "." + field
            if let column = implicitFieldColumn(fullKey) {
                return column
            }
            return "(SELECT COALESCE(valueDate, valueNumber, valueText) FROM properties WHERE documentPath = d.path AND key = '\(baseKey.sqlEscaped)' LIMIT 1)"

        case .stringLiteral(let s):
            return "'\(s.sqlEscaped)'"

        case .numberLiteral(let n):
            if n == n.rounded() && n < 1e15 && n > -1e15 {
                return String(Int(n))
            }
            return String(n)

        case .boolLiteral(let b):
            return b ? "1" : "0"

        case .dateLiteral(let s):
            // Store as ISO string for comparison
            return "'\(s.sqlEscaped)'"

        case .comparison(let left, let op, let right):
            let leftSQL = expressionToSQL(left, context: &context)
            let rightSQL = expressionToSQL(right, context: &context)
            return "(\(leftSQL) \(op.rawValue) \(rightSQL))"

        case .logicalAnd(let left, let right):
            return "(\(buildWhereSQL(left, context: &context)) AND \(buildWhereSQL(right, context: &context)))"

        case .logicalOr(let left, let right):
            return "(\(buildWhereSQL(left, context: &context)) OR \(buildWhereSQL(right, context: &context)))"

        case .logicalNot(let inner):
            return "NOT (\(buildWhereSQL(inner, context: &context)))"

        case .arithmetic(let left, let op, let right):
            let leftSQL = expressionToSQL(left, context: &context)
            let rightSQL = expressionToSQL(right, context: &context)
            if op == .divide {
                return "CASE WHEN (\(rightSQL)) = 0 THEN NULL ELSE (\(leftSQL)) / (\(rightSQL)) END"
            }
            return "(\(leftSQL)) \(op.rawValue) (\(rightSQL))"

        case .negation(let inner):
            return "-(\(expressionToSQL(inner, context: &context)))"

        case .functionCall(let name, let args):
            let argsSQL = args.map { expressionToSQL($0, context: &context) }
            return buildFunctionSQL(name, args: argsSQL)

        case .listLiteral(let items):
            let itemsSQL = items.map { expressionToSQL($0, context: &context) }
            return itemsSQL.joined(separator: ", ")
        }
    }

    // MARK: - Function SQL Generation

    private func buildFunctionSQL(_ name: String, args: [String]) -> String {
        switch name.lowercased() {
        // String functions
        case "length":
            guard let arg = args.first else { return "NULL" }
            return "LENGTH(\(arg))"

        case "lower":
            guard let arg = args.first else { return "NULL" }
            return "LOWER(\(arg))"

        case "upper":
            guard let arg = args.first else { return "NULL" }
            return "UPPER(\(arg))"

        case "startswith":
            guard args.count >= 2 else { return "NULL" }
            return "(\(args[0]) LIKE \(args[1]) || '%')"

        case "endswith":
            guard args.count >= 2 else { return "NULL" }
            return "(\(args[0]) LIKE '%' || \(args[1]))"

        case "replace":
            guard args.count >= 3 else { return "NULL" }
            return "REPLACE(\(args[0]), \(args[1]), \(args[2]))"

        case "regexmatch":
            // SQLite doesn't natively support regex, use LIKE as fallback
            guard args.count >= 2 else { return "NULL" }
            return "(\(args[1]) LIKE '%' || \(args[0]) || '%')"

        case "padleft":
            guard args.count >= 2 else { return "NULL" }
            return "SUBSTR('                    ' || \(args[0]), -\(args[1]))"

        case "padright":
            guard args.count >= 2 else { return "NULL" }
            return "SUBSTR(\(args[0]) || '                    ', 1, \(args[1]))"

        case "substring":
            if args.count >= 3 {
                return "SUBSTR(\(args[0]), \(args[1]) + 1, \(args[2]))"
            } else if args.count >= 2 {
                return "SUBSTR(\(args[0]), \(args[1]) + 1)"
            }
            return "NULL"

        case "truncate":
            guard args.count >= 2 else { return "NULL" }
            return "SUBSTR(\(args[0]), 1, \(args[1]))"

        case "split":
            // Can't truly split in SQL, return the original string
            return args.first ?? "NULL"

        case "join":
            return args.first ?? "NULL"

        // Numeric functions
        case "round":
            if args.count >= 2 {
                return "ROUND(\(args[0]), \(args[1]))"
            }
            guard let arg = args.first else { return "NULL" }
            return "ROUND(\(arg))"

        case "min":
            guard args.count >= 2 else { return args.first ?? "NULL" }
            return "MIN(\(args[0]), \(args[1]))"

        case "max":
            guard args.count >= 2 else { return args.first ?? "NULL" }
            return "MAX(\(args[0]), \(args[1]))"

        case "sum":
            return args.first ?? "NULL"

        case "abs":
            guard let arg = args.first else { return "NULL" }
            return "ABS(\(arg))"

        case "number":
            guard let arg = args.first else { return "NULL" }
            return "CAST(\(arg) AS REAL)"

        case "string":
            guard let arg = args.first else { return "NULL" }
            return "CAST(\(arg) AS TEXT)"

        // Date functions
        case "date":
            guard let arg = args.first else { return "NULL" }
            return arg // dates are already strings in ISO format

        case "dateformat":
            guard args.count >= 2 else { return args.first ?? "NULL" }
            // SQLite strftime - translate common tokens
            return "STRFTIME(\(args[1]), \(args[0]))"

        case "now":
            return "DATETIME('now')"

        // Utility functions
        case "default":
            guard args.count >= 2 else { return args.first ?? "NULL" }
            return "COALESCE(\(args[0]), \(args[1]))"

        case "choice":
            guard args.count >= 3 else { return "NULL" }
            return "CASE WHEN \(args[0]) THEN \(args[1]) ELSE \(args[2]) END"

        case "typeof":
            guard let arg = args.first else { return "NULL" }
            return "TYPEOF(\(arg))"

        case "contains":
            // Already handled in buildContainsSQL for WHERE, but if used in SELECT
            guard args.count >= 2 else { return "0" }
            return "(\(args[0]) LIKE '%' || \(args[1]) || '%')"

        case "link":
            guard let arg = args.first else { return "NULL" }
            return "'[[' || \(arg) || ']]'"

        // List aggregation functions
        case "any":
            return args.first ?? "0"
        case "all":
            return args.first ?? "1"
        case "none":
            guard let arg = args.first else { return "1" }
            return "NOT (\(arg))"
        case "flat":
            return args.first ?? "NULL"
        case "filter":
            return args.first ?? "NULL"
        case "map":
            return args.first ?? "NULL"
        case "sort":
            return args.first ?? "NULL"
        case "reverse":
            return args.first ?? "NULL"

        default:
            // Unknown function — return NULL
            return "NULL"
        }
    }

    // MARK: - Implicit Field Mapping

    /// Map implicit file.* fields and common field shortcuts to document columns
    private func implicitFieldColumn(_ name: String) -> String? {
        switch name.lowercased() {
        case "file.name", "name": return "d.title"
        case "file.path": return "d.path"
        case "file.folder", "folder": return "d.folderPath"
        case "file.mtime", "mtime": return "d.modifiedDate"
        case "file.ctime", "ctime": return "d.modifiedDate" // no ctime stored, fall back to mtime
        case "file.size", "size": return "d.fileSize"
        default: return nil
        }
    }

    /// Map file.* subfield to SQL
    private func implicitFileField(_ field: String) -> String? {
        switch field.lowercased() {
        case "name": return "d.title"
        case "path": return "d.path"
        case "folder": return "d.folderPath"
        case "mtime": return "d.modifiedDate"
        case "ctime": return "d.modifiedDate"
        case "size": return "d.fileSize"
        default: return nil
        }
    }

    // MARK: - Helpers

    private func sanitizeAlias(_ name: String) -> String {
        // Wrap in quotes if it contains special characters
        let safe = name.replacingOccurrences(of: "\"", with: "\"\"")
        if name.contains(".") || name.contains(" ") || name.contains("-") {
            return "\"\(safe)\""
        }
        return safe
    }

    private func rowValueToDataview(_ value: DatabaseValue) -> DataviewValue {
        switch value.storage {
        case .null:
            return .null
        case .int64(let i):
            return .number(Double(i))
        case .double(let d):
            return .number(d)
        case .string(let s):
            // Check if it looks like a date
            if s.count >= 10 && s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
                return .date(s)
            }
            // Check if it looks like a wiki link
            if s.hasPrefix("[[") && s.hasSuffix("]]") {
                let name = String(s.dropFirst(2).dropLast(2))
                return .link(name, name)
            }
            // Check if it's a comma-separated list (from GROUP_CONCAT)
            if s.contains(", ") {
                let items = s.components(separatedBy: ", ")
                if items.count > 1 && items.allSatisfy({ !$0.contains(" ") || $0.hasPrefix("#") || $0.hasPrefix("[[") }) {
                    return .list(items)
                }
            }
            return .text(s)
        case .blob:
            return .null
        }
    }
}

// MARK: - SQL Build Context

private struct SQLBuildContext {
    var joins: [String] = []
    var joinIndex: Int = 0
}

// MARK: - String SQL escaping

private extension String {
    var sqlEscaped: String {
        replacingOccurrences(of: "'", with: "''")
    }
}
