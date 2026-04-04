import Foundation
import GRDB
import SwiftUI

/// Orchestrates Dataview database indexing and query execution.
@Observable
final class DataviewEngine {
    private(set) var isIndexing = false
    private(set) var indexedCount = 0

    private var database: DataviewDatabase?

    /// Initialize and open the database
    func setup() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("DataviewIndex", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("dataview.sqlite").path
        database = try DataviewDatabase(path: dbPath)
        print("📇 [DB] DataviewEngine ready at \(dbPath)")
    }

    /// Setup with an in-memory database (for testing)
    func setupInMemory() throws {
        database = try DataviewDatabase()
    }

    /// Index all vault files
    func indexFiles(_ files: [VaultFile], contentLoader: (VaultFile) -> String, linkResolver: ((String) -> String?)? = nil) async {
        guard let db = database else { return }
        isIndexing = true
        indexedCount = 0

        for file in files {
            let content = contentLoader(file)
            guard !content.isEmpty else { continue }
            do {
                try MetadataIndexer.indexFile(file, content: content, db: db, resolveLink: linkResolver)
                indexedCount += 1
            } catch {
                // Skip files that fail to index
            }
        }

        isIndexing = false
        print("📇 [INDEX] Indexing complete: \(indexedCount)/\(files.count) files indexed")
    }

    /// Re-index only files that changed since last indexing, and prune deleted files.
    /// Uses modifiedDate comparison to detect changes.
    func reindexIfNeeded(_ files: [VaultFile], contentLoader: (VaultFile) -> String, linkResolver: ((String) -> String?)? = nil) async {
        guard let db = database else { return }

        // Get stored timestamps
        let stored: [String: Double]
        do {
            stored = try db.allDocumentTimestamps()
        } catch {
            return
        }

        // Find files that are new or changed
        var changedCount = 0
        for file in files {
            let fileTimestamp = file.modifiedDate.timeIntervalSince1970
            if let storedTimestamp = stored[file.id], storedTimestamp == fileTimestamp {
                continue // unchanged
            }
            let content = contentLoader(file)
            guard !content.isEmpty else { continue }
            do {
                try MetadataIndexer.indexFile(file, content: content, db: db, resolveLink: linkResolver)
                changedCount += 1
            } catch {
                // Skip files that fail
            }
        }

        // Prune documents that no longer exist
        let currentPaths = Set(files.map(\.id))
        try? db.pruneDocuments(keeping: currentPaths)

        if changedCount > 0 {
            indexedCount = (try? db.documentCount()) ?? indexedCount
        }
    }

    /// Execute a DQL query string and return results
    func executeQuery(_ queryString: String) -> DataviewResult? {
        guard let db = database else { return nil }
        FileAccessLogger.shared.log(.dataview, summary: "query")
        do {
            let ast = try DQLParser.parse(queryString)
            let executor = QueryExecutor(db: db)
            return try executor.execute(ast)
        } catch {
            return nil
        }
    }

    /// Execute a DataviewJS code block by translating common patterns to DQL.
    /// Returns nil if the code can't be translated.
    func executeDataviewJS(_ code: String) -> DataviewResult? {
        guard let dql = DataviewJSTranslator.translate(code) else { return nil }
        return executeQuery(dql)
    }

    /// Evaluate an inline DQL expression (e.g., `= this.field`)
    /// Returns a display string for the expression value.
    func evaluateInlineExpression(_ expression: String, forDocument path: String) -> String? {
        guard let db = database else { return nil }

        // Handle `this.field` references
        let expr = expression.trimmingCharacters(in: .whitespacesAndNewlines)

        // `this.field` → look up property for current document
        if expr.hasPrefix("this.") {
            let fieldName = String(expr.dropFirst(5))
            let sql = "SELECT COALESCE(valueDate, valueText) FROM properties WHERE documentPath = ? AND key = ? LIMIT 1"
            do {
                let rows = try db.executeQuery(sql: sql, arguments: StatementArguments([path, fieldName]))
                if let row = rows.first, let val: String = row[Column("COALESCE(valueDate, valueText)")] {
                    return val
                }
                // Try column alias
                if let row = rows.first {
                    for i in 0..<row.count {
                        let dbVal: DatabaseValue = row[i]
                        if case .string(let s) = dbVal.storage { return s }
                        if case .int64(let n) = dbVal.storage { return String(n) }
                        if case .double(let n) = dbVal.storage { return String(n) }
                    }
                }
            } catch {
                // Fall through
            }
            return nil
        }

        // `date(today)` → current date
        if expr == "date(today)" {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: Date())
        }

        return nil
    }

    /// Clear the entire index (for rebuilding)
    func clearIndex() throws {
        try database?.clearAll()
        indexedCount = 0
    }

    /// Fetch display metadata for a batch of files
    func fetchMetadata(for files: [VaultFile]) -> [String: FileMetadata] {
        guard let db = database else { return [:] }
        return (try? db.fetchMetadata(for: files.map(\.id))) ?? [:]
    }

    /// Get count of indexed documents
    var documentCount: Int {
        (try? database?.documentCount()) ?? 0
    }

    /// Search by date range
    func searchByDateRange(from startDate: Date, to endDate: Date, limit: Int = 30) -> [String] {
        guard let db = database else { return [] }
        let results = (try? db.searchByDateRange(from: startDate, to: endDate, limit: limit)) ?? []
        print("📅 [DATE SEARCH] \(startDate) → \(endDate) → \(results.count) results")
        return results
    }

    /// Search by tag
    func searchByTag(tag: String, limit: Int = 30) -> [String] {
        guard let db = database else { return [] }
        let results = (try? db.searchByTag(tag: tag, limit: limit)) ?? []
        print("🏷️ [TAG SEARCH] #\(tag) → \(results.count) results")
        return results
    }

    /// Search by mood
    func searchByMood(mood: String, limit: Int = 30) -> [String] {
        searchByAttribute(key: "mood", value: mood, limit: limit)
    }

    /// Search by any property attribute (key/value). Routes "tag"/"tags" to the tags table.
    func searchByAttribute(key: String, value: String, limit: Int = 30) -> [String] {
        guard let db = database else { return [] }
        let results = (try? db.searchByAttribute(key: key, value: value, limit: limit)) ?? []
        print("🔎 [ATTR SEARCH] \(key)=\(value) → \(results.count) results")
        return results
    }

    /// Query sample values for a property key across the vault to infer type/format.
    /// Returns tuples of (valueText, valueNumber, valueDate) from other notes.
    func propertySamples(key: String, excludingPath: String? = nil, limit: Int = 5) -> [(text: String?, number: Double?, date: String?)] {
        guard let db = database else { return [] }
        var sql = "SELECT valueText, valueNumber, valueDate FROM properties WHERE key = ?"
        var args: [any DatabaseValueConvertible] = [key]
        if let path = excludingPath {
            sql += " AND documentPath != ?"
            args.append(path)
        }
        sql += " LIMIT ?"
        args.append(limit)
        guard let rows = try? db.executeQuery(sql: sql, arguments: StatementArguments(args)) else { return [] }
        return rows.map { row in
            (text: row["valueText"] as String?, number: row["valueNumber"] as Double?, date: row["valueDate"] as String?)
        }
    }

    /// Full-text search returning ranked document paths
    func searchNotes(query: String, limit: Int = 30) -> [String] {
        guard let db = database else {
            print("🔍 [FTS5] Database not initialized!")
            return []
        }
        let results = (try? db.searchNotes(query: query, limit: limit)) ?? []
        print("🔍 [FTS5] \"\(query)\" → \(results.count) results (indexed: \(documentCount) docs)")
        return results
    }
}

