import SwiftUI

/// Reusable context menu for note rows across Search and Browse tabs.
/// Provides: Favorite, Rename, Move, Share actions.
struct NoteContextMenu: ViewModifier {
    let file: VaultFile
    @Environment(VaultManager.self) private var vault
    @Environment(FavoritesManager.self) private var favorites
    @State private var showRenameAlert = false
    @State private var showMoveSheet = false
    @State private var renameText = ""

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    favorites.toggle(file.id)
                } label: {
                    Label(
                        favorites.isFavorite(file.id) ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: favorites.isFavorite(file.id) ? "star.slash" : "star"
                    )
                }

                Divider()

                Button {
                    renameText = file.title
                    showRenameAlert = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button {
                    showMoveSheet = true
                } label: {
                    Label("Move to...", systemImage: "folder")
                }

                Divider()

                Button {
                    let activityVC = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let root = windowScene.windows.first?.rootViewController {
                        root.present(activityVC, animated: true)
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            .alert("Rename Note", isPresented: $showRenameAlert) {
                TextField("Note name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !newName.isEmpty, newName != file.title else { return }
                    vault.renameFile(file, to: newName)
                }
            }
            .sheet(isPresented: $showMoveSheet) {
                MoveToFolderSheet(file: file)
            }
    }
}

extension View {
    func noteContextMenu(file: VaultFile) -> some View {
        modifier(NoteContextMenu(file: file))
    }
}

// MARK: - Folder Picker Sheet

struct MoveToFolderSheet: View {
    let file: VaultFile
    @Environment(VaultManager.self) private var vault
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Root level option
                Button {
                    move(to: "")
                } label: {
                    Label("Vault Root", systemImage: "folder")
                        .foregroundStyle(file.folderPath.isEmpty ? .secondary : .primary)
                }
                .disabled(file.folderPath.isEmpty)

                // Folder tree
                if let tree = vault.folderTree {
                    ForEach(tree.children, id: \.id) { folder in
                        FolderPickerRow(folder: folder, currentFolderPath: file.folderPath) { path in
                            move(to: path)
                        }
                    }
                }
            }
            .navigationTitle("Move \"\(file.title)\"")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func move(to folder: String) {
        vault.moveFile(file, toFolder: folder)
        dismiss()
    }
}

private struct FolderPickerRow: View {
    let folder: VaultFolder
    let currentFolderPath: String
    let onSelect: (String) -> Void

    var body: some View {
        DisclosureGroup {
            ForEach(folder.children, id: \.id) { child in
                FolderPickerRow(folder: child, currentFolderPath: currentFolderPath, onSelect: onSelect)
            }
        } label: {
            Button {
                onSelect(folder.id)
            } label: {
                Label(folder.name, systemImage: "folder")
                    .foregroundStyle(folder.id == currentFolderPath ? .secondary : .primary)
            }
            .disabled(folder.id == currentFolderPath)
        }
    }
}
