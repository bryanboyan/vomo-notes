import Testing
import Foundation
@testable import Vomo

@Suite("Diary Index")
struct DiaryIndexTests {

    private func makeFile(title: String, folderPath: String = "") -> VaultFile {
        VaultFile(
            id: "\(folderPath.isEmpty ? "" : folderPath + "/")\(title).md",
            url: URL(fileURLWithPath: "/vault/\(title).md"),
            title: title,
            relativePath: "\(title).md",
            folderPath: folderPath,
            createdDate: Date(),
            modifiedDate: Date(),
            contentSnippet: "Some content",
            content: nil
        )
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)!
    }

    @Test("Matches exact date title")
    func exactDateTitle() {
        let files = [makeFile(title: "2026-03-22")]
        let index = DiaryIndex(files: files)
        #expect(index.file(for: date("2026-03-22")) != nil)
        #expect(index.totalEntries == 1)
    }

    @Test("Matches date prefix title")
    func datePrefixTitle() {
        let files = [makeFile(title: "2026-03-22 Friday")]
        let index = DiaryIndex(files: files)
        #expect(index.file(for: date("2026-03-22")) != nil)
    }

    @Test("Matches date in middle of title")
    func dateInMiddle() {
        let files = [makeFile(title: "Daily 2026-03-22 notes")]
        let index = DiaryIndex(files: files)
        #expect(index.file(for: date("2026-03-22")) != nil)
    }

    @Test("Does not match non-date titles")
    func nonDateTitle() {
        let files = [makeFile(title: "Meeting Notes")]
        let index = DiaryIndex(files: files)
        #expect(index.totalEntries == 0)
    }

    @Test("Prefers diary folder files")
    func prefersDiaryFolder() {
        let files = [
            makeFile(title: "2026-03-22", folderPath: "Random"),
            makeFile(title: "2026-03-22", folderPath: "Daily Notes"),
        ]
        let index = DiaryIndex(files: files)
        let found = index.file(for: date("2026-03-22"))
        #expect(found?.folderPath == "Daily Notes")
    }

    @Test("Multiple dates indexed")
    func multipleDates() {
        let files = [
            makeFile(title: "2026-03-20"),
            makeFile(title: "2026-03-21"),
            makeFile(title: "2026-03-22"),
        ]
        let index = DiaryIndex(files: files)
        #expect(index.totalEntries == 3)
        #expect(index.file(for: date("2026-03-20")) != nil)
        #expect(index.file(for: date("2026-03-21")) != nil)
        #expect(index.file(for: date("2026-03-22")) != nil)
    }

    @Test("Returns nil for date without entry")
    func noEntry() {
        let files = [makeFile(title: "2026-03-22")]
        let index = DiaryIndex(files: files)
        #expect(index.file(for: date("2026-01-01")) == nil)
    }
}
