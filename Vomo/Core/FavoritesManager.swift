import Foundation

@Observable
final class FavoritesManager {
    private let favoritesKey = "favoriteFilePaths"

    var favoriteIDs: [String] {
        didSet {
            UserDefaults.standard.set(favoriteIDs, forKey: favoritesKey)
        }
    }

    init() {
        self.favoriteIDs = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
    }

    func isFavorite(_ fileID: String) -> Bool {
        favoriteIDs.contains(fileID)
    }

    func toggle(_ fileID: String) {
        if let index = favoriteIDs.firstIndex(of: fileID) {
            favoriteIDs.remove(at: index)
        } else {
            favoriteIDs.append(fileID)
        }
    }

    func add(_ fileID: String) {
        guard !favoriteIDs.contains(fileID) else { return }
        favoriteIDs.append(fileID)
    }

    func remove(_ fileID: String) {
        favoriteIDs.removeAll { $0 == fileID }
    }

    func move(from source: IndexSet, to destination: Int) {
        favoriteIDs.move(fromOffsets: source, toOffset: destination)
    }

    func favoriteFiles(from allFiles: [VaultFile]) -> [VaultFile] {
        favoriteIDs.compactMap { id in allFiles.first { $0.id == id } }
    }
}
