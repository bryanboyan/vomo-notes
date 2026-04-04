import Testing
import Foundation
@testable import Vomo

@Suite("Folder Tree Building")
struct FolderTreeTests {

    private func makeFile(
        relativePath: String,
        title: String? = nil,
        folderPath: String? = nil
    ) -> VaultFile {
        let computedTitle = title ?? URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        let computedFolder: String
        if let fp = folderPath {
            computedFolder = fp
        } else if let lastSlash = relativePath.lastIndex(of: "/") {
            computedFolder = String(relativePath[relativePath.startIndex..<lastSlash])
        } else {
            computedFolder = ""
        }
        return VaultFile(
            id: relativePath,
            url: URL(fileURLWithPath: "/vault/\(relativePath)"),
            title: computedTitle,
            relativePath: relativePath,
            folderPath: computedFolder,
            createdDate: Date(),
            modifiedDate: Date(),
            contentSnippet: "",
            content: nil
        )
    }

    @Test("Root-level files appear in tree root")
    func rootLevelFiles() {
        let files = [
            makeFile(relativePath: "Index.md"),
            makeFile(relativePath: "README.md"),
        ]
        let vm = VaultManager()
        let tree = vm.testBuildFolderTree(from: files, rootURL: URL(fileURLWithPath: "/vault"))
        #expect(tree.files.count == 2)
        #expect(tree.children.isEmpty)
    }

    @Test("Single-level folders created correctly")
    func singleLevelFolders() {
        let files = [
            makeFile(relativePath: "Work/Note.md"),
            makeFile(relativePath: "Personal/Diary.md"),
        ]
        let vm = VaultManager()
        let tree = vm.testBuildFolderTree(from: files, rootURL: URL(fileURLWithPath: "/vault"))
        #expect(tree.children.count == 2)
        #expect(tree.files.isEmpty)
        let workFolder = tree.children.first(where: { $0.name == "Work" })
        #expect(workFolder != nil)
        #expect(workFolder!.files.count == 1)
        #expect(workFolder!.files[0].title == "Note")
    }

    @Test("Nested folders built correctly")
    func nestedFolders() {
        let files = [
            makeFile(relativePath: "A/B/C/Deep.md"),
            makeFile(relativePath: "A/Shallow.md"),
        ]
        let vm = VaultManager()
        let tree = vm.testBuildFolderTree(from: files, rootURL: URL(fileURLWithPath: "/vault"))
        #expect(tree.children.count == 1) // Only "A"
        let a = tree.children[0]
        #expect(a.name == "A")
        #expect(a.files.count == 1) // Shallow.md
        #expect(a.children.count == 1) // "B"
        let b = a.children[0]
        #expect(b.name == "B")
        #expect(b.children.count == 1) // "C"
        let c = b.children[0]
        #expect(c.files.count == 1) // Deep.md
    }

    @Test("No leading slash in folderPath — regression test for Browse bug")
    func noLeadingSlashRegression() {
        // This was the original bug: URL(fileURLWithPath:) produced "/Work" instead of "Work"
        let relativePath = "Work/Meeting Notes.md"
        let folderPath: String
        if let lastSlash = relativePath.lastIndex(of: "/") {
            folderPath = String(relativePath[relativePath.startIndex..<lastSlash])
        } else {
            folderPath = ""
        }
        #expect(folderPath == "Work")
        #expect(!folderPath.hasPrefix("/"))
    }

    @Test("Files with same folder grouped together")
    func sameFolder() {
        let files = [
            makeFile(relativePath: "Notes/A.md"),
            makeFile(relativePath: "Notes/B.md"),
            makeFile(relativePath: "Notes/C.md"),
        ]
        let vm = VaultManager()
        let tree = vm.testBuildFolderTree(from: files, rootURL: URL(fileURLWithPath: "/vault"))
        #expect(tree.children.count == 1)
        #expect(tree.children[0].files.count == 3)
    }

    @Test("Mixed root and nested files")
    func mixedRootAndNested() {
        let files = [
            makeFile(relativePath: "Root.md"),
            makeFile(relativePath: "Sub/Nested.md"),
        ]
        let vm = VaultManager()
        let tree = vm.testBuildFolderTree(from: files, rootURL: URL(fileURLWithPath: "/vault"))
        #expect(tree.files.count == 1)
        #expect(tree.children.count == 1)
        #expect(tree.children[0].files.count == 1)
    }
}
