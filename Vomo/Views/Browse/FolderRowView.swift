import SwiftUI

struct FolderRowView: View {
    let folder: VaultFolder
    @Binding var navigationPath: [VaultFile]
    @Environment(VaultManager.self) var vault
    @Environment(FavoritesManager.self) var favorites
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(folder.children, id: \.id) { child in
                FolderRowView(folder: child, navigationPath: $navigationPath)
            }
            ForEach(folder.files) { file in
                fileRow(file)
            }
        } label: {
            Label {
                HStack {
                    Text(folder.name)
                    Spacer()
                    Text("\(totalFileCount(in: folder))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } icon: {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .foregroundStyle(Color.obsidianPurple)
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

    private func totalFileCount(in folder: VaultFolder) -> Int {
        folder.files.count + folder.children.reduce(0) { $0 + totalFileCount(in: $1) }
    }
}
