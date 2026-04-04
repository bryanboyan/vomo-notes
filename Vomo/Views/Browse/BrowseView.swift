import SwiftUI

struct BrowseView: View {
    @Environment(VaultManager.self) var vault
    @Environment(FavoritesManager.self) var favorites
    @Environment(\.showSettingsAction) var showSettings
    @Binding var navigationPath: [VaultFile]
    @State private var editingFavorites = false

    var body: some View {
        List {
            favoritesSection
            foldersSection
        }
        .listStyle(.sidebar)
        .navigationTitle("Browse")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings() } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .refreshable {
            await vault.scanVault()
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        let favFiles = favorites.favoriteFiles(from: vault.files)
        if !favFiles.isEmpty {
            Section {
                ForEach(favFiles) { file in
                    Button {
                        vault.markAsRecent(file)
                        navigationPath.append(file)
                    } label: {
                        Label(file.title, systemImage: "star.fill")
                            .foregroundStyle(.primary)
                    }
                    .noteContextMenu(file: file)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            favorites.remove(file.id)
                        } label: {
                            Label("Unfavorite", systemImage: "star.slash")
                        }
                    }
                }
                .onMove { from, to in
                    favorites.move(from: from, to: to)
                }
            } header: {
                HStack {
                    Text("Favorites")
                    Spacer()
                    Button(editingFavorites ? "Done" : "Edit") {
                        editingFavorites.toggle()
                    }
                    .font(.caption)
                }
            }
            .environment(\.editMode, .constant(editingFavorites ? .active : .inactive))
        }
    }

    @ViewBuilder
    private var foldersSection: some View {
        if let tree = vault.folderTree {
            Section("Folders") {
                ForEach(tree.children, id: \.id) { folder in
                    FolderRowView(folder: folder, navigationPath: $navigationPath)
                }
                ForEach(tree.files) { file in
                    fileRow(file)
                }
            }
        }
    }

    private func fileRow(_ file: VaultFile) -> some View {
        Button {
            vault.markAsRecent(file)
            navigationPath.append(file)
        } label: {
            Label(file.title, systemImage: "doc.text")
                .foregroundStyle(.primary)
        }
        .noteContextMenu(file: file)
        .swipeActions(edge: .leading) {
            Button {
                favorites.toggle(file.id)
            } label: {
                Label("Favorite", systemImage: "star")
            }
            .tint(.yellow)
        }
    }
}
