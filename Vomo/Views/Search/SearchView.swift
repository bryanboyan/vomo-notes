import SwiftUI

struct SearchView: View {
    @Environment(VaultManager.self) var vault
    @Environment(DataviewEngine.self) var dataview
    @Environment(\.showSettingsAction) var showSettings
    @Binding var navigationPath: [VaultFile]
    var onMicTapped: (() -> Void)?
    @State private var searchText = ""
    @State private var searchResults: [VaultFile] = []
    @State private var metadataCache: [String: FileMetadata] = [:]
    @FocusState private var isSearchFocused: Bool

    private var isSearching: Bool { !searchText.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // Content area
            ScrollView {
                LazyVStack(spacing: 0) {
                    if isSearching {
                        searchResultsSection
                    } else {
                        recentFilesSection
                    }
                }
                .padding(.bottom, 16)
            }

            // Bottom search bar (Safari-style)
            bottomSearchBar
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings() } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: searchText) { _, newValue in
            Task { await performSearch(query: newValue) }
        }
        .task(id: vault.files.count) {
            await loadMetadata(for: vault.files)
        }
        .refreshable {
            await vault.scanVault()
        }
    }

    // MARK: - Bottom Search Bar

    private var bottomSearchBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    TextField("Search notes...", text: $searchText)
                        .focused($isSearchFocused)
                        .font(.body)
                        .submitLabel(.search)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))

                if isSearchFocused {
                    Button("Cancel") {
                        searchText = ""
                        isSearchFocused = false
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.obsidianPurple)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if let onMicTapped {
                    Button {
                        onMicTapped()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .font(.subheadline)
                            Text("Voice")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.obsidianPurple, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
            .animation(.easeInOut(duration: 0.2), value: isSearchFocused)
        }
    }

    // MARK: - Search Results

    @ViewBuilder
    private var searchResultsSection: some View {
        if searchResults.isEmpty {
            ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("No notes matching \"\(searchText)\""))
                .padding(.top, 60)
        } else {
            HStack {
                Text("Results")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(searchResults.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.cardBackground, in: Capsule())
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ForEach(searchResults) { file in
                Button {
                    vault.markAsRecent(file)
                    navigationPath.append(file)
                } label: {
                    SearchResultRow(file: file, highlightText: searchText, metadata: metadataCache[file.id])
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .noteContextMenu(file: file)
                Divider().padding(.leading)
            }
        }
    }

    // MARK: - Recent / All Files

    @ViewBuilder
    private var recentFilesSection: some View {
        let recents = vault.recentFiles
        let totalFiles = vault.files.count

        if recents.isEmpty {
            if totalFiles == 0 {
                ContentUnavailableView("No Notes", systemImage: "doc.text", description: Text("Your vault appears empty"))
                    .padding(.top, 60)
            } else {
                sectionHeader("All Notes", count: totalFiles)

                ForEach(vault.files.prefix(50)) { file in
                    Button {
                        vault.markAsRecent(file)
                        navigationPath.append(file)
                    } label: {
                        SearchResultRow(file: file, highlightText: nil, metadata: metadataCache[file.id])
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .noteContextMenu(file: file)
                    Divider().padding(.leading)
                }

                if totalFiles > 50 {
                    Text("\(totalFiles - 50) more notes...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        } else {
            sectionHeader("Recent", count: recents.count)

            ForEach(recents) { file in
                Button {
                    vault.markAsRecent(file)
                    navigationPath.append(file)
                } label: {
                    SearchResultRow(file: file, highlightText: nil, metadata: metadataCache[file.id])
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .noteContextMenu(file: file)
                Divider().padding(.leading)
            }

            if totalFiles > recents.count {
                sectionHeader("All Notes", count: totalFiles)

                ForEach(vault.files.prefix(30)) { file in
                    if !recents.contains(where: { $0.id == file.id }) {
                        Button {
                            vault.markAsRecent(file)
                            navigationPath.append(file)
                        } label: {
                            SearchResultRow(file: file, highlightText: nil, metadata: metadataCache[file.id])
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .noteContextMenu(file: file)
                        Divider().padding(.leading)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.cardBackground, in: Capsule())
        }
        .padding(.horizontal)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    // MARK: - Search Logic

    private func loadMetadata(for files: [VaultFile]) async {
        let batch = Array(files.prefix(100))
        let engine = dataview
        let fetched = await Task.detached(priority: .userInitiated) {
            engine.fetchMetadata(for: batch)
        }.value
        metadataCache.merge(fetched) { _, new in new }
    }

    private func performSearch(query: String) async {
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        FileAccessLogger.shared.log(.search, summary: "\"\(query)\"")

        // Snapshot data needed for background work
        let files = vault.files
        let engine = dataview

        let results = await Task.detached(priority: .userInitiated) {
            // FTS5 ranked search
            let rankedPaths = engine.searchNotes(query: query)
            if !rankedPaths.isEmpty {
                let filesByPath = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                return rankedPaths.compactMap { filesByPath[$0] }
            }

            // Fallback: substring match
            let lowered = query.lowercased()
            let fallback = files.filter { file in
                file.title.localizedCaseInsensitiveContains(lowered) ||
                file.contentSnippet.localizedCaseInsensitiveContains(lowered) ||
                (file.content?.localizedCaseInsensitiveContains(lowered) ?? false)
            }.sorted { a, b in
                let aTitle = a.title.localizedCaseInsensitiveContains(lowered)
                let bTitle = b.title.localizedCaseInsensitiveContains(lowered)
                if aTitle != bTitle { return aTitle }
                return a.modifiedDate > b.modifiedDate
            }
            return fallback
        }.value

        searchResults = results
        if !results.isEmpty {
            await loadMetadata(for: results)
        }
    }
}
