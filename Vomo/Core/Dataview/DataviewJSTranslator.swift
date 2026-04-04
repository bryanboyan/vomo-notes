import Foundation

/// Translates common DataviewJS patterns into DQL queries.
/// This provides basic support for the most common `dv.pages()` patterns
/// without requiring a full JavaScript runtime.
struct DataviewJSTranslator {

    /// Attempt to translate DataviewJS code into a DQL query string.
    /// Returns nil if the code uses patterns we can't translate.
    static func translate(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to match common patterns
        if let result = translateTablePattern(trimmed) { return result }
        if let result = translateListPattern(trimmed) { return result }
        if let result = translatePagesPattern(trimmed) { return result }

        return nil
    }

    // MARK: - Pattern: dv.table(headers, pages.map(...))

    private static func translateTablePattern(_ code: String) -> String? {
        // Match: dv.table(["col1", "col2"], dv.pages("source").map(p => [p.field1, p.field2]))
        guard code.contains("dv.table") else { return nil }

        // Extract headers
        let headers = extractTableHeaders(code)
        guard !headers.isEmpty else { return nil }

        // Extract source
        let source = extractSource(code)

        // Extract field mappings from .map()
        let fields = extractMapFields(code)

        // Build DQL
        var dql = "TABLE"
        if !fields.isEmpty {
            dql += " " + fields.joined(separator: ", ")
        } else if !headers.isEmpty {
            dql += " " + headers.joined(separator: ", ")
        }
        if let source = source {
            dql += " FROM \(source)"
        }

        // Extract .where() filter
        if let filter = extractWhereFilter(code) {
            dql += " WHERE \(filter)"
        }

        // Extract .sort()
        if let sort = extractSort(code) {
            dql += " SORT \(sort)"
        }

        // Extract .limit()
        if let limit = extractLimit(code) {
            dql += " LIMIT \(limit)"
        }

        return dql
    }

    // MARK: - Pattern: dv.list(pages.map(...))

    private static func translateListPattern(_ code: String) -> String? {
        guard code.contains("dv.list") else { return nil }

        let source = extractSource(code)
        var dql = "LIST"

        // Extract field from map if present
        let fields = extractMapFields(code)
        if let field = fields.first {
            dql += " \(field)"
        }

        if let source = source {
            dql += " FROM \(source)"
        }

        if let filter = extractWhereFilter(code) {
            dql += " WHERE \(filter)"
        }

        if let sort = extractSort(code) {
            dql += " SORT \(sort)"
        }

        if let limit = extractLimit(code) {
            dql += " LIMIT \(limit)"
        }

        return dql
    }

    // MARK: - Pattern: dv.pages("source") (simple listing)

    private static func translatePagesPattern(_ code: String) -> String? {
        guard code.contains("dv.pages") else { return nil }

        let source = extractSource(code)
        var dql = "LIST"

        if let source = source {
            dql += " FROM \(source)"
        }

        if let filter = extractWhereFilter(code) {
            dql += " WHERE \(filter)"
        }

        if let sort = extractSort(code) {
            dql += " SORT \(sort)"
        }

        if let limit = extractLimit(code) {
            dql += " LIMIT \(limit)"
        }

        return dql
    }

    // MARK: - Extraction Helpers

    private static func extractSource(_ code: String) -> String? {
        // Match dv.pages("source") or dv.pages('#tag')
        guard let regex = try? NSRegularExpression(pattern: #"dv\.pages\(\s*["']([^"']+)["']\s*\)"#) else { return nil }
        let nsCode = code as NSString
        if let match = regex.firstMatch(in: code, range: NSRange(location: 0, length: nsCode.length)),
           let range = Range(match.range(at: 1), in: code) {
            let source = String(code[range])
            if source.hasPrefix("#") {
                return source
            }
            return "\"\(source)\""
        }
        return nil
    }

    private static func extractTableHeaders(_ code: String) -> [String] {
        // Match: dv.table(["Header1", "Header2"], ...)
        guard let regex = try? NSRegularExpression(pattern: #"dv\.table\(\s*\[([^\]]+)\]"#) else { return [] }
        let nsCode = code as NSString
        guard let match = regex.firstMatch(in: code, range: NSRange(location: 0, length: nsCode.length)),
              let range = Range(match.range(at: 1), in: code) else { return [] }

        let content = String(code[range])
        return content.components(separatedBy: ",").compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func extractMapFields(_ code: String) -> [String] {
        // Match: .map(p => [p.field1, p.field2]) or .map(p => p.field)
        guard let regex = try? NSRegularExpression(pattern: #"\.map\(\s*\w+\s*=>\s*\[?([^\])\n]+)"#) else { return [] }
        let nsCode = code as NSString
        guard let match = regex.firstMatch(in: code, range: NSRange(location: 0, length: nsCode.length)),
              let range = Range(match.range(at: 1), in: code) else { return [] }

        let content = String(code[range])
        return content.components(separatedBy: ",").compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            // Extract field name from p.fieldName
            if let dotIndex = trimmed.firstIndex(of: ".") {
                let field = String(trimmed[trimmed.index(after: dotIndex)...]).trimmingCharacters(in: .whitespaces)
                return field.isEmpty ? nil : field
            }
            return nil
        }
    }

    private static func extractWhereFilter(_ code: String) -> String? {
        // Match: .where(p => p.field op value) or .filter(p => p.field op value)
        guard let regex = try? NSRegularExpression(pattern: #"\.(where|filter)\(\s*\w+\s*=>\s*(.+?)\)"#) else { return nil }
        let nsCode = code as NSString
        guard let match = regex.firstMatch(in: code, range: NSRange(location: 0, length: nsCode.length)),
              let range = Range(match.range(at: 2), in: code) else { return nil }

        var filter = String(code[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Replace p.field with just field
        if let fieldRegex = try? NSRegularExpression(pattern: #"\w+\.(\w+)"#) {
            filter = fieldRegex.stringByReplacingMatches(
                in: filter, range: NSRange(location: 0, length: (filter as NSString).length),
                withTemplate: "$1"
            )
        }
        // Replace === with =, !== with !=
        filter = filter.replacingOccurrences(of: "===", with: "=")
        filter = filter.replacingOccurrences(of: "!==", with: "!=")
        // Replace && with AND, || with OR
        filter = filter.replacingOccurrences(of: "&&", with: " AND ")
        filter = filter.replacingOccurrences(of: "||", with: " OR ")

        return filter.isEmpty ? nil : filter
    }

    private static func extractSort(_ code: String) -> String? {
        // Match: .sort(p => p.field, 'asc') or .sort(p => -p.field)
        guard let regex = try? NSRegularExpression(pattern: #"\.sort\(\s*(?:\w+\s*=>\s*)?(-?)(?:\w+\.)?(\w+)(?:\s*,\s*['"](\w+)['"])?\s*\)"#) else { return nil }
        let nsCode = code as NSString
        guard let match = regex.firstMatch(in: code, range: NSRange(location: 0, length: nsCode.length)) else { return nil }

        let negate = match.range(at: 1).length > 0
        guard let fieldRange = Range(match.range(at: 2), in: code) else { return nil }
        let field = String(code[fieldRange])

        var direction = "ASC"
        if negate {
            direction = "DESC"
        }
        if match.range(at: 3).length > 0, let dirRange = Range(match.range(at: 3), in: code) {
            let dir = String(code[dirRange]).lowercased()
            direction = dir == "desc" ? "DESC" : "ASC"
        }

        return "\(field) \(direction)"
    }

    private static func extractLimit(_ code: String) -> Int? {
        // Match: .limit(N) or .slice(0, N)
        if let regex = try? NSRegularExpression(pattern: #"\.(?:limit|slice)\(\s*(?:\d+\s*,\s*)?(\d+)\s*\)"#),
           let match = regex.firstMatch(in: code, range: NSRange(location: 0, length: (code as NSString).length)),
           let range = Range(match.range(at: 1), in: code) {
            return Int(String(code[range]))
        }
        return nil
    }
}
