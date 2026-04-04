import Testing
import Foundation
@testable import Vomo

@Suite("Search Filtering")
struct SearchTests {

    private func makeFile(title: String, content: String?, snippet: String = "") -> VaultFile {
        VaultFile(
            id: "\(title).md",
            url: URL(fileURLWithPath: "/vault/\(title).md"),
            title: title,
            relativePath: "\(title).md",
            folderPath: "",
            createdDate: Date(),
            modifiedDate: Date(),
            contentSnippet: snippet,
            content: content
        )
    }

    private func search(_ query: String, in files: [VaultFile]) -> [VaultFile] {
        let lowered = query.lowercased()
        return files.filter { file in
            file.title.localizedCaseInsensitiveContains(lowered) ||
            file.contentSnippet.localizedCaseInsensitiveContains(lowered) ||
            (file.content?.localizedCaseInsensitiveContains(lowered) ?? false)
        }.sorted { a, b in
            let aTitle = a.title.localizedCaseInsensitiveContains(lowered)
            let bTitle = b.title.localizedCaseInsensitiveContains(lowered)
            if aTitle != bTitle { return aTitle }
            return a.modifiedDate > b.modifiedDate
        }
    }

    @Test("Title match ranks higher than content match")
    func titleMatchFirst() {
        let files = [
            makeFile(title: "Unrelated", content: "Has the word meeting in body"),
            makeFile(title: "Meeting Notes", content: "Some agenda items"),
        ]
        let results = search("meeting", in: files)
        #expect(results.count == 2)
        #expect(results[0].title == "Meeting Notes") // title match first
    }

    @Test("Case-insensitive search")
    func caseInsensitive() {
        let files = [makeFile(title: "Hello", content: "WORLD")]
        #expect(search("hello", in: files).count == 1)
        #expect(search("HELLO", in: files).count == 1)
        #expect(search("world", in: files).count == 1)
    }

    @Test("Empty query returns no results")
    func emptyQuery() {
        let files = [makeFile(title: "Test", content: "Content")]
        #expect(search("", in: files).isEmpty)
    }

    @Test("Snippet search works")
    func snippetSearch() {
        let files = [makeFile(title: "Note", content: nil, snippet: "Contains special keyword")]
        let results = search("keyword", in: files)
        #expect(results.count == 1)
    }

    @Test("No match returns empty")
    func noMatch() {
        let files = [makeFile(title: "Alpha", content: "Beta")]
        #expect(search("zzzzz", in: files).isEmpty)
    }
}
