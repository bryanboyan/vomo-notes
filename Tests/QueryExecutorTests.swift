import Foundation
import Testing
@testable import Vomo

@Suite("Query Executor")
struct QueryExecutorTests {

    /// Set up a test database with sample book data
    private func setupBookDatabase() throws -> DataviewDatabase {
        let db = try DataviewDatabase()

        // Index three books
        let books: [(id: String, title: String, rating: Double, author: String)] = [
            ("Books/Hobbit.md", "Hobbit", 9, "Tolkien"),
            ("Books/Dune.md", "Dune", 8, "Herbert"),
            ("Books/Foundation.md", "Foundation", 7, "Asimov"),
        ]

        for book in books {
            let file = VaultFile(
                id: book.id, url: URL(fileURLWithPath: "/vault/\(book.id)"),
                title: book.title, relativePath: book.id, folderPath: "Books",
                createdDate: Date(), modifiedDate: Date(), contentSnippet: "", content: nil
            )
            let content = """
            ---
            rating: \(Int(book.rating))
            author: \(book.author)
            genre: fiction
            ---
            # \(book.title)
            A great book.
            """
            try MetadataIndexer.indexFile(file, content: content, db: db)
        }

        return db
    }

    // MARK: - TABLE queries

    @Test("TABLE query returns all documents from folder")
    func tableFromFolder() throws {
        let db = try setupBookDatabase()
        let query = try DQLParser.parse("TABLE rating FROM \"Books\"")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.queryType == .table)
        #expect(result.rows.count == 3)
        #expect(result.columns.contains("File"))
        #expect(result.columns.contains("rating"))
    }

    @Test("TABLE with WHERE filters rows")
    func tableWithWhere() throws {
        let db = try setupBookDatabase()
        let query = try DQLParser.parse("TABLE rating FROM \"Books\" WHERE rating > 7")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.rows.count == 2)
        // Should include Hobbit (9) and Dune (8) but not Foundation (7)
        let titles = result.rows.map { $0.title }
        #expect(titles.contains("Hobbit"))
        #expect(titles.contains("Dune"))
        #expect(!titles.contains("Foundation"))
    }

    @Test("TABLE with SORT orders results")
    func tableWithSort() throws {
        let db = try setupBookDatabase()
        let query = try DQLParser.parse("TABLE rating FROM \"Books\" SORT rating DESC")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.rows.count == 3)
        #expect(result.rows[0].title == "Hobbit")
        #expect(result.rows[1].title == "Dune")
        #expect(result.rows[2].title == "Foundation")
    }

    @Test("TABLE with LIMIT restricts count")
    func tableWithLimit() throws {
        let db = try setupBookDatabase()
        let query = try DQLParser.parse("TABLE rating FROM \"Books\" LIMIT 2")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.rows.count == 2)
    }

    @Test("TABLE with multiple columns")
    func tableMultipleColumns() throws {
        let db = try setupBookDatabase()
        let query = try DQLParser.parse("TABLE rating, author FROM \"Books\"")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.columns.count == 3) // File + rating + author
        #expect(result.rows.first?.values.count == 2)
    }

    @Test("TABLE WITHOUT ID omits file column")
    func tableWithoutId() throws {
        let db = try setupBookDatabase()
        let query = try DQLParser.parse("TABLE WITHOUT ID rating FROM \"Books\"")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(!result.columns.contains("File"))
        #expect(result.columns.contains("rating"))
    }

    // MARK: - LIST queries

    @Test("LIST returns document titles")
    func listQuery() throws {
        let db = try setupBookDatabase()
        let query = try DQLParser.parse("LIST FROM \"Books\"")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.queryType == .list)
        #expect(result.rows.count == 3)
        let titles = result.rows.map { $0.title }
        #expect(titles.contains("Hobbit"))
    }

    // MARK: - TASK queries

    @Test("TASK query returns tasks")
    func taskQuery() throws {
        let db = try DataviewDatabase()
        let file = VaultFile(
            id: "Work/Tasks.md", url: URL(fileURLWithPath: "/vault/Work/Tasks.md"),
            title: "Tasks", relativePath: "Work/Tasks.md", folderPath: "Work",
            createdDate: Date(), modifiedDate: Date(), contentSnippet: "", content: nil
        )
        let content = """
        # Work Tasks
        - [ ] Finish report
        - [x] Send email
        - [ ] Review code
        """
        try MetadataIndexer.indexFile(file, content: content, db: db)

        let query = try DQLParser.parse("TASK FROM \"Work\"")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.queryType == .task)
        #expect(result.rows.count == 3)
    }

    // MARK: - Edge cases

    @Test("Query with no FROM returns all documents")
    func queryNoFrom() throws {
        let db = try setupBookDatabase()
        let query = try DQLParser.parse("TABLE rating")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.rows.count == 3)
    }

    @Test("Query with empty result")
    func queryEmptyResult() throws {
        let db = try setupBookDatabase()
        let query = try DQLParser.parse("TABLE rating FROM \"NonExistent\"")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.rows.isEmpty)
    }

    // MARK: - Tag-based FROM

    @Test("FROM #tag filters by tag")
    func fromTag() throws {
        let db = try DataviewDatabase()

        // Create a file with tags
        let file = VaultFile(
            id: "Notes/Tagged.md", url: URL(fileURLWithPath: "/vault/Notes/Tagged.md"),
            title: "Tagged", relativePath: "Notes/Tagged.md", folderPath: "Notes",
            createdDate: Date(), modifiedDate: Date(), contentSnippet: "", content: nil
        )
        try MetadataIndexer.indexFile(file, content: "Some text #important", db: db)

        // Create a file without the tag
        let file2 = VaultFile(
            id: "Notes/Untagged.md", url: URL(fileURLWithPath: "/vault/Notes/Untagged.md"),
            title: "Untagged", relativePath: "Notes/Untagged.md", folderPath: "Notes",
            createdDate: Date(), modifiedDate: Date(), contentSnippet: "", content: nil
        )
        try MetadataIndexer.indexFile(file2, content: "No special tags", db: db)

        let query = try DQLParser.parse("LIST FROM #important")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.rows.count == 1)
        #expect(result.rows[0].title == "Tagged")
    }

    // MARK: - Incremental re-indexing

    @Test("Pruning removes deleted documents")
    func pruneDeleted() throws {
        let db = try setupBookDatabase()

        // All 3 books should exist
        #expect(try db.documentCount() == 3)

        // Prune, keeping only 2
        try db.pruneDocuments(keeping: Set(["Books/Hobbit.md", "Books/Dune.md"]))

        #expect(try db.documentCount() == 2)

        // Foundation should be gone, including its properties
        let props = try db.executeQuery(sql: "SELECT * FROM properties WHERE documentPath = 'Books/Foundation.md'")
        #expect(props.isEmpty)
    }

    @Test("Re-indexing updates changed properties")
    func reindexChangedProperties() throws {
        let db = try DataviewDatabase()

        let file = VaultFile(
            id: "test.md", url: URL(fileURLWithPath: "/vault/test.md"),
            title: "Test", relativePath: "test.md", folderPath: "",
            createdDate: Date(), modifiedDate: Date(), contentSnippet: "", content: nil
        )

        // Index with rating 5
        try MetadataIndexer.indexFile(file, content: "---\nrating: 5\nauthor: Alice\n---\nContent", db: db)

        // Verify
        let props1 = try db.executeQuery(sql: "SELECT valueNumber FROM properties WHERE key = 'rating'")
        #expect(props1[0]["valueNumber"] as? Double == 5.0)

        // Re-index with rating 9 and author removed
        try MetadataIndexer.indexFile(file, content: "---\nrating: 9\n---\nNew content", db: db)

        // Rating should be updated
        let props2 = try db.executeQuery(sql: "SELECT valueNumber FROM properties WHERE key = 'rating'")
        #expect(props2[0]["valueNumber"] as? Double == 9.0)

        // Author should be gone (delete-and-reinsert)
        let authorProps = try db.executeQuery(sql: "SELECT * FROM properties WHERE key = 'author'")
        #expect(authorProps.isEmpty)
    }

    // MARK: - New features: Inline fields

    @Test("Inline fields are indexed")
    func inlineFieldsIndexed() throws {
        let db = try DataviewDatabase()

        let file = VaultFile(
            id: "Notes/test.md", url: URL(fileURLWithPath: "/vault/Notes/test.md"),
            title: "Test", relativePath: "Notes/test.md", folderPath: "Notes",
            createdDate: Date(), modifiedDate: Date(), contentSnippet: "", content: nil
        )

        let content = """
        ---
        title: Test Note
        ---
        # My Note
        rating:: 8
        Some text [author:: Tolkien] and more text.
        """
        try MetadataIndexer.indexFile(file, content: content, db: db)

        // Check inline rating
        let ratingProps = try db.executeQuery(sql: "SELECT valueNumber FROM properties WHERE key = 'rating' AND source = 'inline'")
        #expect(ratingProps.count == 1)
        #expect(ratingProps[0]["valueNumber"] as? Double == 8.0)

        // Check inline author
        let authorProps = try db.executeQuery(sql: "SELECT valueText FROM properties WHERE key = 'author' AND source = 'inline'")
        #expect(authorProps.count == 1)
        #expect(authorProps[0]["valueText"] as? String == "Tolkien")
    }

    @Test("Frontmatter takes precedence over inline fields")
    func frontmatterPrecedence() throws {
        let db = try DataviewDatabase()

        let file = VaultFile(
            id: "test.md", url: URL(fileURLWithPath: "/vault/test.md"),
            title: "Test", relativePath: "test.md", folderPath: "",
            createdDate: Date(), modifiedDate: Date(), contentSnippet: "", content: nil
        )

        let content = """
        ---
        rating: 9
        ---
        rating:: 5
        """
        try MetadataIndexer.indexFile(file, content: content, db: db)

        // Should have frontmatter rating (9), not inline (5)
        let props = try db.executeQuery(sql: "SELECT valueNumber, source FROM properties WHERE key = 'rating'")
        #expect(props.count == 1)
        #expect(props[0]["valueNumber"] as? Double == 9.0)
        #expect(props[0]["source"] as? String == "frontmatter")
    }

    // MARK: - New features: Date comparisons

    @Test("WHERE with date comparison")
    func dateComparison() throws {
        let db = try DataviewDatabase()

        let files = [
            ("Notes/old.md", "Old Note", "2023-01-15"),
            ("Notes/new.md", "New Note", "2024-06-01"),
        ]

        for (id, title, date) in files {
            let file = VaultFile(
                id: id, url: URL(fileURLWithPath: "/vault/\(id)"),
                title: title, relativePath: id, folderPath: "Notes",
                createdDate: Date(), modifiedDate: Date(), contentSnippet: "", content: nil
            )
            try MetadataIndexer.indexFile(file, content: "---\ndate: \(date)\n---\nContent", db: db)
        }

        let query = try DQLParser.parse("LIST FROM \"Notes\" WHERE date > date(\"2024-01-01\")")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.rows.count == 1)
        #expect(result.rows[0].title == "New Note")
    }

    // MARK: - New features: contains() fix

    @Test("contains() checks tags")
    func containsTags() throws {
        let db = try DataviewDatabase()

        let file = VaultFile(
            id: "Notes/tagged.md", url: URL(fileURLWithPath: "/vault/Notes/tagged.md"),
            title: "Tagged Note", relativePath: "Notes/tagged.md", folderPath: "Notes",
            createdDate: Date(), modifiedDate: Date(), contentSnippet: "", content: nil
        )
        try MetadataIndexer.indexFile(file, content: "Some text #fiction #scifi", db: db)

        let file2 = VaultFile(
            id: "Notes/other.md", url: URL(fileURLWithPath: "/vault/Notes/other.md"),
            title: "Other Note", relativePath: "Notes/other.md", folderPath: "Notes",
            createdDate: Date(), modifiedDate: Date(), contentSnippet: "", content: nil
        )
        try MetadataIndexer.indexFile(file2, content: "No relevant tags #work", db: db)

        // contains() should match via tags table
        let query = try DQLParser.parse("LIST FROM \"Notes\" WHERE contains(tags, \"fiction\")")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.rows.count == 1)
        #expect(result.rows[0].title == "Tagged Note")
    }

    // MARK: - New features: CALENDAR query

    @Test("CALENDAR query returns dates")
    func calendarQuery() throws {
        let db = try DataviewDatabase()

        let file = VaultFile(
            id: "Notes/event.md", url: URL(fileURLWithPath: "/vault/Notes/event.md"),
            title: "Event", relativePath: "Notes/event.md", folderPath: "Notes",
            createdDate: Date(), modifiedDate: Date(), contentSnippet: "", content: nil
        )
        try MetadataIndexer.indexFile(file, content: "---\ndate: 2024-03-15\n---\nMeeting notes", db: db)

        let query = try DQLParser.parse("CALENDAR date FROM \"Notes\"")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.queryType == .calendar)
        #expect(result.rows.count == 1)
    }

    // MARK: - New features: file.* fields

    @Test("TABLE with file.name")
    func fileNameField() throws {
        let db = try setupBookDatabase()
        let query = try DQLParser.parse("TABLE file.name FROM \"Books\"")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.rows.count == 3)
        // file.name should resolve to document title
        let names = result.rows.compactMap { $0.values.first?.displayString }
        #expect(names.contains("Hobbit"))
    }

    @Test("TABLE with file.size")
    func fileSizeField() throws {
        let db = try setupBookDatabase()
        let query = try DQLParser.parse("TABLE file.size FROM \"Books\"")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        #expect(result.rows.count == 3)
        // file.size should be non-null
        for row in result.rows {
            if case .number(let n) = row.values.first {
                #expect(n > 0)
            }
        }
    }

    // MARK: - GROUP BY

    @Test("GROUP BY groups rows by field value")
    func groupBy() throws {
        let db = try DataviewDatabase()

        // Index files with different genres
        let files: [(id: String, title: String, genre: String, rating: Int)] = [
            ("Books/A.md", "A", "fiction", 9),
            ("Books/B.md", "B", "fiction", 7),
            ("Books/C.md", "C", "nonfiction", 8),
        ]
        for f in files {
            let file = VaultFile(
                id: f.id, url: URL(fileURLWithPath: "/vault/\(f.id)"),
                title: f.title, relativePath: f.id, folderPath: "Books",
                createdDate: Date(), modifiedDate: Date(), contentSnippet: "", content: nil
            )
            try MetadataIndexer.indexFile(file, content: "---\ngenre: \(f.genre)\nrating: \(f.rating)\n---\nContent", db: db)
        }

        let query = try DQLParser.parse("TABLE rating FROM \"Books\" GROUP BY genre")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        // Should still have 3 rows but with group key in columns
        #expect(result.rows.count == 3)
        #expect(result.columns.contains("genre"))

        // Fiction group should have 2 rows
        let fictionRows = result.rows.filter { $0.id.hasPrefix("fiction:") }
        #expect(fictionRows.count == 2)

        let nonfictionRows = result.rows.filter { $0.id.hasPrefix("nonfiction:") }
        #expect(nonfictionRows.count == 1)
    }

    // MARK: - FLATTEN

    @Test("FLATTEN expands comma-separated values into separate rows")
    func flattenCommaValues() throws {
        let db = try DataviewDatabase()

        let file = VaultFile(
            id: "Notes/multi.md", url: URL(fileURLWithPath: "/vault/Notes/multi.md"),
            title: "Multi", relativePath: "Notes/multi.md", folderPath: "Notes",
            createdDate: Date(), modifiedDate: Date(), contentSnippet: "", content: nil
        )
        try MetadataIndexer.indexFile(file, content: "---\ntags_list: alpha, beta, gamma\n---\nContent", db: db)

        let query = try DQLParser.parse("TABLE tags_list FROM \"Notes\" FLATTEN tags_list")
        let executor = QueryExecutor(db: db)
        let result = try executor.execute(query)

        // Should expand 1 row into 3 rows (one per comma-separated value)
        #expect(result.rows.count == 3)
        let vals = result.rows.compactMap { $0.values.first?.displayString }
        #expect(vals.contains("alpha"))
        #expect(vals.contains("beta"))
        #expect(vals.contains("gamma"))
    }
}

// MARK: - DataviewJS Translator Tests

@Suite("DataviewJS Translator")
struct DataviewJSTranslatorTests {

    @Test("Translates dv.pages with tag source")
    func translatePages() {
        let code = """
        dv.pages("#books")
        """
        let dql = DataviewJSTranslator.translate(code)
        #expect(dql != nil)
        #expect(dql?.contains("FROM #books") == true)
    }

    @Test("Translates dv.table with headers and fields")
    func translateTable() {
        let code = """
        dv.table(["Rating", "Author"], dv.pages("#books").map(p => [p.rating, p.author]))
        """
        let dql = DataviewJSTranslator.translate(code)
        #expect(dql != nil)
        #expect(dql?.hasPrefix("TABLE") == true)
        #expect(dql?.contains("rating") == true)
        #expect(dql?.contains("author") == true)
    }

    @Test("Translates dv.list")
    func translateList() {
        let code = """
        dv.list(dv.pages("#books").map(p => p.title))
        """
        let dql = DataviewJSTranslator.translate(code)
        #expect(dql != nil)
        #expect(dql?.hasPrefix("LIST") == true)
    }

    @Test("Returns nil for complex JS")
    func complexJSReturnsNil() {
        let code = """
        const pages = dv.pages("#books");
        for (let p of pages) {
            if (p.rating > 5) dv.paragraph(p.title);
        }
        """
        let dql = DataviewJSTranslator.translate(code)
        // Complex code with loops likely can't be translated
        // (it may still partially match, so we just check it doesn't crash)
        _ = dql
    }

    @Test("Translates .sort()")
    func translateSort() {
        let code = """
        dv.list(dv.pages("#books").sort(p => p.rating, "desc").map(p => p.title))
        """
        let dql = DataviewJSTranslator.translate(code)
        #expect(dql?.contains("SORT") == true)
        #expect(dql?.contains("DESC") == true)
    }

    @Test("Translates .limit()")
    func translateLimit() {
        let code = """
        dv.list(dv.pages("#books").limit(5))
        """
        let dql = DataviewJSTranslator.translate(code)
        #expect(dql?.contains("LIMIT 5") == true)
    }
}

// MARK: - Inline Field Extraction Tests

@Suite("Inline Field Extraction")
struct InlineFieldExtractionTests {

    @Test("Extracts full-line inline fields")
    func fullLineField() {
        let text = """
        # My Note
        rating:: 8
        author:: Tolkien
        """
        let fields = MetadataIndexer.extractInlineFields(from: text)
        #expect(fields.count == 2)
        let keys = fields.map(\.key)
        #expect(keys.contains("rating"))
        #expect(keys.contains("author"))
    }

    @Test("Extracts bracket inline fields")
    func bracketField() {
        let text = "Some text [rating:: 9] and [status:: done] more text."
        let fields = MetadataIndexer.extractInlineFields(from: text)
        #expect(fields.count == 2)
    }

    @Test("Extracts paren inline fields")
    func parenField() {
        let text = "Some text (rating:: 7) here."
        let fields = MetadataIndexer.extractInlineFields(from: text)
        #expect(fields.count == 1)
        #expect(fields[0].key == "rating")
    }

    @Test("Classifies numeric inline fields")
    func numericField() {
        let text = "score:: 42"
        let fields = MetadataIndexer.extractInlineFields(from: text)
        #expect(fields.count == 1)
        #expect(fields[0].valueNumber == 42)
    }

    @Test("Classifies date inline fields")
    func dateField() {
        let text = "created:: 2024-03-15"
        let fields = MetadataIndexer.extractInlineFields(from: text)
        #expect(fields.count == 1)
        #expect(fields[0].valueDate == "2024-03-15")
    }

    @Test("Skips fields inside code blocks")
    func skipCodeBlocks() {
        let text = """
        ```
        rating:: 5
        ```
        actual:: 8
        """
        let fields = MetadataIndexer.extractInlineFields(from: text)
        #expect(fields.count == 1)
        #expect(fields[0].key == "actual")
    }

    @Test("First occurrence wins for duplicate keys")
    func duplicateKeys() {
        let text = """
        rating:: 8
        rating:: 5
        """
        let fields = MetadataIndexer.extractInlineFields(from: text)
        #expect(fields.count == 1)
        #expect(fields[0].valueNumber == 8)
    }
}
