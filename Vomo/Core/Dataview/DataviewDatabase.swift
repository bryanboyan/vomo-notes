import Foundation
import GRDB

// MARK: - Database Records

struct DocumentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "documents"

    var path: String
    var title: String
    var folderPath: String
    var modifiedDate: Double    // Unix timestamp
    var fileSize: Int
}

struct PropertyRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "properties"

    var documentPath: String
    var key: String
    var valueText: String?
    var valueNumber: Double?
    var valueDate: String?
    var source: String

    enum Columns {
        static let documentPath = Column(CodingKeys.documentPath)
        static let key = Column(CodingKeys.key)
        static let valueText = Column(CodingKeys.valueText)
        static let valueNumber = Column(CodingKeys.valueNumber)
        static let valueDate = Column(CodingKeys.valueDate)
        static let source = Column(CodingKeys.source)
    }
}

struct PropertyValueRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "propertyValues"

    var documentPath: String
    var key: String
    var valueText: String
    var sortOrder: Int
}

struct TagRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tags"

    var documentPath: String
    var tag: String
}

struct LinkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "links"

    var sourcePath: String
    var targetPath: String
    var targetResolved: String?
    var displayText: String?
}

struct TaskRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tasks"

    var id: Int64?
    var documentPath: String
    var text: String
    var completed: Bool
    var lineNumber: Int?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct AliasRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "aliases"

    var documentPath: String
    var alias: String
}

// MARK: - Database Manager

final class DataviewDatabase {
    let dbWriter: DatabaseWriter

    init(path: String) throws {
        let dbPool = try DatabasePool(path: path)
        self.dbWriter = dbPool
        try migrator.migrate(dbPool)
    }

    /// In-memory database for testing
    init() throws {
        let dbQueue = try DatabaseQueue()
        self.dbWriter = dbQueue
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "documents") { t in
                t.primaryKey("path", .text)
                t.column("title", .text).notNull()
                t.column("folderPath", .text).notNull()
                t.column("modifiedDate", .double).notNull()
                t.column("fileSize", .integer).defaults(to: 0)
            }

            try db.create(table: "properties") { t in
                t.column("documentPath", .text)
                    .notNull()
                    .references("documents", column: "path", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("valueText", .text)
                t.column("valueNumber", .double)
                t.column("valueDate", .text)
                t.column("source", .text).notNull().defaults(to: "frontmatter")
                t.primaryKey(["documentPath", "key", "source"])
            }

            try db.create(table: "propertyValues") { t in
                t.column("documentPath", .text)
                    .notNull()
                    .references("documents", column: "path", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("valueText", .text).notNull()
                t.column("sortOrder", .integer).defaults(to: 0)
            }

            try db.create(table: "tags") { t in
                t.column("documentPath", .text)
                    .notNull()
                    .references("documents", column: "path", onDelete: .cascade)
                t.column("tag", .text).notNull()
                t.primaryKey(["documentPath", "tag"])
            }

            try db.create(table: "links") { t in
                t.column("sourcePath", .text)
                    .notNull()
                    .references("documents", column: "path", onDelete: .cascade)
                t.column("targetPath", .text).notNull()
                t.column("targetResolved", .text)
                t.column("displayText", .text)
                t.primaryKey(["sourcePath", "targetPath"])
            }

            try db.create(table: "tasks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("documentPath", .text)
                    .notNull()
                    .references("documents", column: "path", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("completed", .boolean).notNull().defaults(to: false)
                t.column("lineNumber", .integer)
            }

            try db.create(table: "aliases") { t in
                t.column("documentPath", .text)
                    .notNull()
                    .references("documents", column: "path", onDelete: .cascade)
                t.column("alias", .text).notNull()
                t.primaryKey(["documentPath", "alias"])
            }

            // Indexes
            try db.create(index: "idx_properties_key", on: "properties", columns: ["key"])
            try db.create(index: "idx_tags_tag", on: "tags", columns: ["tag"])
            try db.create(index: "idx_links_target", on: "links", columns: ["targetResolved"])
            try db.create(index: "idx_tasks_doc", on: "tasks", columns: ["documentPath"])
        }

        migrator.registerMigration("v2-fts") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS noteSearch USING fts5(
                    title,
                    body,
                    tags,
                    tokenize='porter unicode61'
                )
                """)
        }

        return migrator
    }

    // MARK: - CRUD Operations

    func insertDocument(_ doc: DocumentRecord) throws {
        try dbWriter.write { db in
            try doc.insert(db, onConflict: .replace)
        }
    }

    func deleteDocument(path: String) throws {
        try dbWriter.write { db in
            _ = try DocumentRecord.deleteOne(db, key: path)
        }
    }

    func insertProperty(_ prop: PropertyRecord) throws {
        try dbWriter.write { db in
            try prop.insert(db, onConflict: .replace)
        }
    }

    func insertPropertyValue(_ pv: PropertyValueRecord) throws {
        try dbWriter.write { db in
            try pv.insert(db)
        }
    }

    func insertTag(_ tag: TagRecord) throws {
        try dbWriter.write { db in
            try tag.insert(db, onConflict: .ignore)
        }
    }

    func insertLink(_ link: LinkRecord) throws {
        try dbWriter.write { db in
            try link.insert(db, onConflict: .replace)
        }
    }

    func insertTask(_ task: TaskRecord) throws {
        try dbWriter.write { [task] db in
            var record = task
            try record.insert(db)
        }
    }

    func insertAlias(_ alias: AliasRecord) throws {
        try dbWriter.write { db in
            try alias.insert(db, onConflict: .ignore)
        }
    }

    /// Clear all data for a document before re-indexing
    func clearDocument(path: String) throws {
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM properties WHERE documentPath = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM propertyValues WHERE documentPath = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM tags WHERE documentPath = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM links WHERE sourcePath = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM tasks WHERE documentPath = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM aliases WHERE documentPath = ?", arguments: [path])
        }
    }

    /// Index a document and all its metadata in a single transaction
    func indexDocument(
        _ doc: DocumentRecord,
        properties: [PropertyRecord],
        propertyValues: [PropertyValueRecord],
        tags: [TagRecord],
        links: [LinkRecord],
        tasks: [TaskRecord],
        aliases: [AliasRecord]
    ) throws {
        try dbWriter.write { db in
            // Clear existing data
            try db.execute(sql: "DELETE FROM properties WHERE documentPath = ?", arguments: [doc.path])
            try db.execute(sql: "DELETE FROM propertyValues WHERE documentPath = ?", arguments: [doc.path])
            try db.execute(sql: "DELETE FROM tags WHERE documentPath = ?", arguments: [doc.path])
            try db.execute(sql: "DELETE FROM links WHERE sourcePath = ?", arguments: [doc.path])
            try db.execute(sql: "DELETE FROM tasks WHERE documentPath = ?", arguments: [doc.path])
            try db.execute(sql: "DELETE FROM aliases WHERE documentPath = ?", arguments: [doc.path])

            // Insert document
            try doc.insert(db, onConflict: .replace)

            // Insert all metadata
            for prop in properties { try prop.insert(db, onConflict: .replace) }
            for pv in propertyValues { try pv.insert(db) }
            for tag in tags { try tag.insert(db, onConflict: .ignore) }
            for link in links { try link.insert(db, onConflict: .replace) }
            for task in tasks { var record = task; try record.insert(db) }
            for alias in aliases { try alias.insert(db, onConflict: .ignore) }
        }
    }

    /// Execute a raw SQL query and return rows as dictionaries
    func executeQuery(sql: String, arguments: StatementArguments = StatementArguments()) throws -> [Row] {
        try dbWriter.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    /// Get document count
    func documentCount() throws -> Int {
        try dbWriter.read { db in
            try DocumentRecord.fetchCount(db)
        }
    }

    /// Fetch all stored document paths and their modifiedDate timestamps
    func allDocumentTimestamps() throws -> [String: Double] {
        try dbWriter.read { db in
            var result: [String: Double] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT path, modifiedDate FROM documents")
            for row in rows {
                if let path: String = row["path"], let ts: Double = row["modifiedDate"] {
                    result[path] = ts
                }
            }
            return result
        }
    }

    /// Delete documents whose paths are no longer in the vault
    func pruneDocuments(keeping currentPaths: Set<String>) throws {
        let stored = try allDocumentTimestamps()
        let stale = Set(stored.keys).subtracting(currentPaths)
        guard !stale.isEmpty else { return }
        try dbWriter.write { db in
            for path in stale {
                // Delete FTS entry before deleting document (need rowid)
                if let row = try Row.fetchOne(db, sql: "SELECT rowid FROM documents WHERE path = ?", arguments: [path]),
                   let rowid: Int64 = row["rowid"] {
                    try db.execute(sql: "DELETE FROM noteSearch WHERE rowid = ?", arguments: [rowid])
                }
                // CASCADE deletes handle properties, tags, links, tasks, aliases
                _ = try DocumentRecord.deleteOne(db, key: path)
            }
        }
    }

    /// Fetch display metadata (date, mood, tags) for a batch of document paths
    func fetchMetadata(for paths: [String]) throws -> [String: FileMetadata] {
        guard !paths.isEmpty else { return [:] }
        return try dbWriter.read { db in
            var result: [String: FileMetadata] = [:]

            // Build placeholders
            let placeholders = paths.map { _ in "?" }.joined(separator: ",")
            let args = StatementArguments(paths)

            // Fetch relevant properties (date, end_date, endDate, mood)
            let propSQL = """
                SELECT documentPath, key, valueText, valueDate
                FROM properties
                WHERE documentPath IN (\(placeholders))
                  AND LOWER(key) IN ('date', 'end_date', 'enddate', 'mood')
                """
            let propRows = try Row.fetchAll(db, sql: propSQL, arguments: args)

            // Group by path
            var dateMap: [String: String] = [:]
            var endDateMap: [String: String] = [:]
            var moodMap: [String: String] = [:]

            for row in propRows {
                guard let path: String = row["documentPath"],
                      let key: String = row["key"] else { continue }
                let value = (row["valueDate"] as String?) ?? (row["valueText"] as String?) ?? ""
                guard !value.isEmpty else { continue }
                switch key.lowercased() {
                case "date": dateMap[path] = value
                case "end_date", "enddate": endDateMap[path] = value
                case "mood": moodMap[path] = value
                default: break
                }
            }

            // Fetch tags (up to 3 per document)
            let tagSQL = """
                SELECT documentPath, tag FROM tags
                WHERE documentPath IN (\(placeholders))
                ORDER BY documentPath, tag
                """
            let tagRows = try Row.fetchAll(db, sql: tagSQL, arguments: args)

            var tagsMap: [String: [String]] = [:]
            for row in tagRows {
                guard let path: String = row["documentPath"],
                      let tag: String = row["tag"] else { continue }
                tagsMap[path, default: []].append(tag)
            }

            // Assemble
            for path in paths {
                let tags = Array((tagsMap[path] ?? []).prefix(3))
                let meta = FileMetadata(
                    date: dateMap[path],
                    endDate: endDateMap[path],
                    mood: moodMap[path],
                    tags: tags
                )
                if !meta.isEmpty {
                    result[path] = meta
                }
            }

            return result
        }
    }

    /// Clear entire database
    func clearAll() throws {
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM tasks")
            try db.execute(sql: "DELETE FROM links")
            try db.execute(sql: "DELETE FROM tags")
            try db.execute(sql: "DELETE FROM propertyValues")
            try db.execute(sql: "DELETE FROM properties")
            try db.execute(sql: "DELETE FROM aliases")
            try db.execute(sql: "DELETE FROM documents")
            try db.execute(sql: "DELETE FROM noteSearch")
        }
    }

    // MARK: - Full-Text Search

    /// Index a document's content into the FTS5 table.
    /// Uses rowid = documents table rowid convention via INSERT with explicit rowid.
    func indexNoteContent(path: String, title: String, body: String, tags: [String]) throws {
        try dbWriter.write { db in
            // Get the rowid for this document
            guard let row = try Row.fetchOne(db, sql: "SELECT rowid FROM documents WHERE path = ?", arguments: [path]),
                  let rowid: Int64 = row["rowid"] else { return }

            // Delete old FTS entry if exists
            try db.execute(sql: "DELETE FROM noteSearch WHERE rowid = ?", arguments: [rowid])

            // Insert new FTS entry
            try db.execute(
                sql: "INSERT INTO noteSearch(rowid, title, body, tags) VALUES (?, ?, ?, ?)",
                arguments: [rowid, title, body, tags.joined(separator: " ")]
            )
        }
    }

    /// Full-text search returning ranked document paths.
    func searchNotes(query: String, limit: Int = 30) throws -> [String] {
        try dbWriter.read { db in
            // Build FTS5 query: add * suffix for prefix matching on last term
            let terms = query
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard !terms.isEmpty else { return [] }

            // Quote each term and add prefix matching to the last term
            var queryParts: [String] = []
            for (i, term) in terms.enumerated() {
                let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
                if i == terms.count - 1 {
                    queryParts.append("\"" + escaped + "\"*")
                } else {
                    queryParts.append("\"" + escaped + "\"")
                }
            }
            let ftsQuery: String = queryParts.joined(separator: " ")

            let rows = try Row.fetchAll(
                db,
                sql: "SELECT d.path FROM noteSearch ns JOIN documents d ON d.rowid = ns.rowid WHERE noteSearch MATCH ? ORDER BY bm25(noteSearch, 10.0, 1.0, 5.0) LIMIT " + String(limit),
                arguments: StatementArguments([ftsQuery as DatabaseValueConvertible])
            )
            return rows.compactMap { $0["path"] as String? }
        }
    }

    /// Search documents by date range
    func searchByDateRange(from startDate: Date, to endDate: Date, limit: Int = 30) throws -> [String] {
        try dbWriter.read { db in
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let startStr = formatter.string(from: startDate)
            let endStr = formatter.string(from: endDate)

            let sql = """
                SELECT DISTINCT documentPath FROM properties
                WHERE LOWER(key) IN ('date', 'created', 'modified')
                  AND valueDate >= ? AND valueDate <= ?
                ORDER BY valueDate DESC
                LIMIT ?
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [startStr, endStr, limit])
            return rows.compactMap { $0["documentPath"] as String? }
        }
    }

    /// Search documents by tag
    func searchByTag(tag: String, limit: Int = 30) throws -> [String] {
        try dbWriter.read { db in
            let cleanTag = tag.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            let sql = """
                SELECT documentPath FROM tags
                WHERE tag = ?
                ORDER BY documentPath
                LIMIT ?
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [cleanTag, limit])
            return rows.compactMap { $0["documentPath"] as String? }
        }
    }

    /// Search documents by mood
    func searchByMood(mood: String, limit: Int = 30) throws -> [String] {
        try searchByAttribute(key: "mood", value: mood, limit: limit)
    }

    /// Search documents by any property attribute (key/value pair).
    /// Special-cases "tag"/"tags" to search the tags table instead of properties.
    func searchByAttribute(key: String, value: String, limit: Int = 30) throws -> [String] {
        let lowerKey = key.lowercased()
        if lowerKey == "tag" || lowerKey == "tags" {
            return try searchByTag(tag: value, limit: limit)
        }
        return try dbWriter.read { db in
            let sql = """
                SELECT documentPath FROM properties
                WHERE LOWER(key) = LOWER(?) AND LOWER(valueText) = LOWER(?)
                ORDER BY documentPath DESC
                LIMIT ?
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [key, value, limit])
            return rows.compactMap { $0["documentPath"] as String? }
        }
    }
}
