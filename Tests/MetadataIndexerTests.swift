import Foundation
import Testing
@testable import Vomo

@Suite("Metadata Indexer")
struct MetadataIndexerTests {

    private func makeFile(
        id: String = "test.md",
        title: String = "Test",
        folderPath: String = ""
    ) -> VaultFile {
        VaultFile(
            id: id,
            url: URL(fileURLWithPath: "/vault/\(id)"),
            title: title,
            relativePath: id,
            folderPath: folderPath,
            createdDate: Date(),
            modifiedDate: Date(),
            contentSnippet: "",
            content: nil
        )
    }

    @Test("Indexes frontmatter properties")
    func indexFrontmatter() throws {
        let db = try DataviewDatabase()
        let file = makeFile()
        let content = """
        ---
        rating: 8
        author: Tolkien
        ---
        # The Hobbit
        """

        try MetadataIndexer.indexFile(file, content: content, db: db)

        let docs = try db.executeQuery(sql: "SELECT COUNT(*) as cnt FROM documents")
        #expect(docs[0]["cnt"] as? Int64 == 1)

        let props = try db.executeQuery(sql: "SELECT * FROM properties WHERE key = 'rating'")
        #expect(props.count == 1)
        #expect(props[0]["valueNumber"] as? Double == 8.0)

        let authorProps = try db.executeQuery(sql: "SELECT * FROM properties WHERE key = 'author'")
        #expect(authorProps.count == 1)
        #expect(authorProps[0]["valueText"] as? String == "Tolkien")
    }

    @Test("Indexes tags from body")
    func indexBodyTags() throws {
        let db = try DataviewDatabase()
        let file = makeFile()
        let content = "# Note\nSome text with #book and #fiction tags"

        try MetadataIndexer.indexFile(file, content: content, db: db)

        let tags = try db.executeQuery(sql: "SELECT tag FROM tags ORDER BY tag")
        #expect(tags.count == 2)
        #expect(tags[0]["tag"] as? String == "book")
        #expect(tags[1]["tag"] as? String == "fiction")
    }

    @Test("Indexes frontmatter tags")
    func indexFrontmatterTags() throws {
        let db = try DataviewDatabase()
        let file = makeFile()
        let content = """
        ---
        tags: [book, review]
        ---
        # My Review
        """

        try MetadataIndexer.indexFile(file, content: content, db: db)

        let tags = try db.executeQuery(sql: "SELECT tag FROM tags ORDER BY tag")
        #expect(tags.count == 2)
        #expect(tags[0]["tag"] as? String == "book")
        #expect(tags[1]["tag"] as? String == "review")
    }

    @Test("Indexes wiki links")
    func indexLinks() throws {
        let db = try DataviewDatabase()
        let file = makeFile()
        let content = "See [[Other Note]] and [[Another|Display Text]]"

        try MetadataIndexer.indexFile(file, content: content, db: db)

        let links = try db.executeQuery(sql: "SELECT targetPath FROM links ORDER BY targetPath")
        #expect(links.count == 2)
        #expect(links[0]["targetPath"] as? String == "Another")
        #expect(links[1]["targetPath"] as? String == "Other Note")
    }

    @Test("Indexes tasks")
    func indexTasks() throws {
        let db = try DataviewDatabase()
        let file = makeFile()
        let content = """
        # Todo
        - [ ] Buy groceries
        - [x] Write tests
        - [ ] Review PR
        """

        try MetadataIndexer.indexFile(file, content: content, db: db)

        let tasks = try db.executeQuery(sql: "SELECT text, completed FROM tasks ORDER BY lineNumber")
        #expect(tasks.count == 3)
        #expect(tasks[0]["text"] as? String == "Buy groceries")
        #expect(tasks[0]["completed"] as? Int64 == 0)
        #expect(tasks[1]["text"] as? String == "Write tests")
        #expect(tasks[1]["completed"] as? Int64 == 1)
    }

    @Test("Indexes boolean properties")
    func indexBooleans() throws {
        let db = try DataviewDatabase()
        let file = makeFile()
        let content = """
        ---
        published: true
        draft: false
        ---
        Content
        """

        try MetadataIndexer.indexFile(file, content: content, db: db)

        let published = try db.executeQuery(sql: "SELECT valueNumber FROM properties WHERE key = 'published'")
        #expect(published[0]["valueNumber"] as? Double == 1.0)

        let draft = try db.executeQuery(sql: "SELECT valueNumber FROM properties WHERE key = 'draft'")
        #expect(draft[0]["valueNumber"] as? Double == 0.0)
    }

    @Test("Indexes date properties")
    func indexDates() throws {
        let db = try DataviewDatabase()
        let file = makeFile()
        let content = """
        ---
        created: 2024-01-15
        ---
        Content
        """

        try MetadataIndexer.indexFile(file, content: content, db: db)

        let props = try db.executeQuery(sql: "SELECT valueDate FROM properties WHERE key = 'created'")
        #expect(props[0]["valueDate"] as? String == "2024-01-15")
    }

    @Test("Re-indexing replaces previous data")
    func reindex() throws {
        let db = try DataviewDatabase()
        let file = makeFile()

        try MetadataIndexer.indexFile(file, content: "---\nrating: 5\n---\n#old", db: db)
        try MetadataIndexer.indexFile(file, content: "---\nrating: 9\n---\n#new", db: db)

        let docs = try db.executeQuery(sql: "SELECT COUNT(*) as cnt FROM documents")
        #expect(docs[0]["cnt"] as? Int64 == 1)

        let props = try db.executeQuery(sql: "SELECT valueNumber FROM properties WHERE key = 'rating'")
        #expect(props[0]["valueNumber"] as? Double == 9.0)

        let tags = try db.executeQuery(sql: "SELECT tag FROM tags")
        #expect(tags.count == 1)
        #expect(tags[0]["tag"] as? String == "new")
    }

    @Test("Indexes aliases from frontmatter")
    func indexAliases() throws {
        let db = try DataviewDatabase()
        let file = makeFile()
        let content = """
        ---
        aliases: [nickname, shortname]
        ---
        Content
        """

        try MetadataIndexer.indexFile(file, content: content, db: db)

        let aliases = try db.executeQuery(sql: "SELECT alias FROM aliases ORDER BY alias")
        #expect(aliases.count == 2)
        #expect(aliases[0]["alias"] as? String == "nickname")
        #expect(aliases[1]["alias"] as? String == "shortname")
    }

    @Test("Indexes file metadata correctly")
    func indexFileMetadata() throws {
        let db = try DataviewDatabase()
        let file = makeFile(id: "Books/Hobbit.md", title: "Hobbit", folderPath: "Books")
        let content = "# The Hobbit\nA book by Tolkien"

        try MetadataIndexer.indexFile(file, content: content, db: db)

        let docs = try db.executeQuery(sql: "SELECT path, title, folderPath FROM documents")
        #expect(docs[0]["path"] as? String == "Books/Hobbit.md")
        #expect(docs[0]["title"] as? String == "Hobbit")
        #expect(docs[0]["folderPath"] as? String == "Books")
    }
}
