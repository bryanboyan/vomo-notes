import SwiftUI

/// Settings view for controlling which vault folders the voice agent can search.
/// Supports three modes: All (no filter), Include Only (whitelist), Exclude (blacklist).
struct VoiceSearchScopeView: View {
    @Environment(VaultManager.self) private var vault

    enum ScopeMode: String, CaseIterable {
        case all = "All"
        case include = "Include Only"
        case exclude = "Exclude"
    }

    @State private var mode: ScopeMode = .all
    @State private var selectedFolders: Set<String> = []

    private let settings = SettingsManager.shared

    var body: some View {
        List {
            Section {
                Picker("Scope", selection: $mode) {
                    ForEach(ScopeMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            } footer: {
                switch mode {
                case .all:
                    Text("Voice search will look in all folders.")
                case .include:
                    Text("Voice search will only look in selected folders.")
                case .exclude:
                    Text("Voice search will skip selected folders.")
                }
            }

            if mode != .all {
                Section("Folders") {
                    if let tree = vault.folderTree {
                        ForEach(tree.children) { folder in
                            folderRow(folder, depth: 0)
                        }
                    }
                }
            }
        }
        .navigationTitle("Search Scope")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadState() }
        .onChange(of: mode) { _, newMode in
            handleModeChange(newMode)
        }
    }

    // MARK: - Folder rows

    private func folderRow(_ folder: VaultFolder, depth: Int) -> AnyView {
        AnyView(
            Group {
                Button {
                    toggleFolder(folder.id)
                } label: {
                    HStack {
                        ForEach(0..<depth, id: \.self) { _ in
                            Spacer().frame(width: 16)
                        }
                        Image(systemName: "folder")
                            .foregroundStyle(Color.obsidianPurple)
                        Text(folder.name)
                        Spacer()
                        if selectedFolders.contains(folder.id) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.obsidianPurple)
                        }
                    }
                }
                .foregroundStyle(.primary)

                ForEach(folder.children) { child in
                    folderRow(child, depth: depth + 1)
                }
            }
        )
    }

    // MARK: - State management

    private func loadState() {
        if !settings.voiceSearchIncludeFolders.isEmpty {
            mode = .include
            selectedFolders = Set(settings.voiceSearchIncludeFolders)
        } else if !settings.voiceSearchExcludeFolders.isEmpty {
            mode = .exclude
            selectedFolders = Set(settings.voiceSearchExcludeFolders)
        } else {
            mode = .all
            selectedFolders = []
        }
    }

    private func handleModeChange(_ newMode: ScopeMode) {
        selectedFolders = []
        settings.voiceSearchIncludeFolders = []
        settings.voiceSearchExcludeFolders = []
    }

    private func toggleFolder(_ folderId: String) {
        if selectedFolders.contains(folderId) {
            selectedFolders.remove(folderId)
        } else {
            selectedFolders.insert(folderId)
        }
        persist()
    }

    private func persist() {
        switch mode {
        case .all:
            settings.voiceSearchIncludeFolders = []
            settings.voiceSearchExcludeFolders = []
        case .include:
            settings.voiceSearchIncludeFolders = Array(selectedFolders).sorted()
            settings.voiceSearchExcludeFolders = []
        case .exclude:
            settings.voiceSearchIncludeFolders = []
            settings.voiceSearchExcludeFolders = Array(selectedFolders).sorted()
        }
    }
}
