import Foundation

struct VaultFile: Identifiable, Hashable {
    let id: String          // relative path from vault root
    let url: URL
    let title: String       // filename without .md
    let relativePath: String
    let folderPath: String  // parent folder relative path
    let createdDate: Date
    let modifiedDate: Date
    var contentSnippet: String
    var content: String?    // loaded on-demand for reading, always loaded for search

    var isFolder: Bool { false }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: VaultFile, rhs: VaultFile) -> Bool {
        lhs.id == rhs.id
    }
}

struct VaultFolder: Identifiable, Hashable {
    let id: String          // relative path
    let name: String
    let url: URL
    var children: [VaultFolder]
    var files: [VaultFile]

    var allItems: [(isFolder: Bool, name: String, id: String)] {
        let folders = children.map { (isFolder: true, name: $0.name, id: $0.id) }
        let fileItems = files.map { (isFolder: false, name: $0.title, id: $0.id) }
        return folders.sorted { $0.name < $1.name } + fileItems.sorted { $0.name < $1.name }
    }
}
