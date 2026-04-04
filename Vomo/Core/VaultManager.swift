import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum SyncState: Equatable {
    case idle
    case loadingCache
    case scanning
    case downloading(completed: Int, total: Int)
    case syncing
}

@Observable
final class VaultManager {
    var vaultURL: URL?
    var embeddingsURL: URL?
    var files: [VaultFile] = []
    var folderTree: VaultFolder?
    var graph: VaultGraph = .empty
    private var graphStale = false
    var syncState: SyncState = .idle
    var lastSyncDate: Date?
    var scanStatus: String = ""  // human-readable scan status

    let downloadMonitor = ICloudDownloadMonitor()
    private var cache: VaultCache?
    private var syncTask: Task<Void, Never>?

    private let bookmarkKey = "vaultBookmarkData"
    private let embeddingsBookmarkKey = "embeddingsBookmarkData"
    private let vaultPathKey = "vaultDirectPath"
    private let recentFilesKey = "recentFiles"
    private let maxRecentFiles = 20
    private(set) var isLocalPath = false

    var hasVault: Bool { vaultURL != nil }
    var isLoading: Bool { syncState != .idle }

    /// Resolved embeddings URL: custom override, or default {vault}/.embeddings/
    var resolvedEmbeddingsURL: URL? {
        if let embeddingsURL { return embeddingsURL }
        return vaultURL?.appendingPathComponent(".embeddings")
    }
    var hasEmbeddings: Bool {
        guard let url = resolvedEmbeddingsURL else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("index.json").path)
    }

    /// Display-friendly vault path (last 2 components to avoid just showing "Documents")
    var vaultDisplayPath: String {
        guard let url = vaultURL else { return "Unknown" }
        let components = url.pathComponents.filter { $0 != "/" }
        if components.count >= 2 {
            return components.suffix(2).joined(separator: "/")
        }
        return url.lastPathComponent
    }

    var recentFileIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: recentFilesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: recentFilesKey) }
    }

    var recentFiles: [VaultFile] {
        let ids = recentFileIDs
        return ids.compactMap { id in files.first { $0.id == id } }
    }

    /// Display-friendly embeddings path
    var embeddingsDisplayPath: String {
        if let url = embeddingsURL {
            let components = url.pathComponents.filter { $0 != "/" }
            if components.count >= 2 {
                return components.suffix(2).joined(separator: "/")
            }
            return url.lastPathComponent
        }
        return ".embeddings (default)"
    }

    init() {
        restoreBookmark()
        if vaultURL == nil {
            restoreDirectPath()
        }
        if let vaultURL {
            cache = VaultCache(vaultURL: vaultURL)
        }
        restoreEmbeddingsBookmark()
    }

    // MARK: - Bookmark Management

    func saveBookmark(for url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to start security-scoped access for bookmark")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            vaultURL = url
            cache = VaultCache(vaultURL: url)
        } catch {
            print("Failed to save bookmark: \(error)")
        }
    }

    func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
            guard url.startAccessingSecurityScopedResource() else {
                print("Failed to start security-scoped access for restored bookmark")
                return
            }
            if isStale {
                // Re-save to refresh the bookmark data while we have access
                let freshData = try url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(freshData, forKey: bookmarkKey)
            }
            vaultURL = url
        } catch {
            print("Failed to restore bookmark: \(error)")
        }
    }

    // MARK: - Embeddings Bookmark

    func saveEmbeddingsBookmark(for url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: embeddingsBookmarkKey)
            embeddingsURL = url
        } catch {
            print("Failed to save embeddings bookmark: \(error)")
        }
    }

    func clearEmbeddingsBookmark() {
        UserDefaults.standard.removeObject(forKey: embeddingsBookmarkKey)
        embeddingsURL = nil
    }

    private func restoreEmbeddingsBookmark() {
        guard let data = UserDefaults.standard.data(forKey: embeddingsBookmarkKey) else { return }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
            guard url.startAccessingSecurityScopedResource() else { return }
            if isStale {
                let freshData = try url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(freshData, forKey: embeddingsBookmarkKey)
            }
            embeddingsURL = url
        } catch {
            print("Failed to restore embeddings bookmark: \(error)")
        }
    }

    // MARK: - Direct Path (for local/sandbox vaults)

    func setDirectPath(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: vaultPathKey)
        isLocalPath = true
        vaultURL = url
        cache = VaultCache(vaultURL: url)
    }

    private func restoreDirectPath() {
        guard let path = UserDefaults.standard.string(forKey: vaultPathKey) else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            isLocalPath = true
            vaultURL = url
        }
    }

    // MARK: - Sample Vault

    func createSampleVault() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let vaultDir = docs.appendingPathComponent("SampleVault")
        let fm = FileManager.default

        try? fm.createDirectory(at: vaultDir.appendingPathComponent("Work"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: vaultDir.appendingPathComponent("Personal"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: vaultDir.appendingPathComponent("Daily Notes"), withIntermediateDirectories: true)

        let sampleFiles: [(String, String)] = [
            ("Index.md", "# My Vault Index\n\nWelcome to the test vault!\n\n## Quick Links\n- [[Meeting Notes]]\n- [[Project Ideas]]\n- [[Reading List]]\n\n#index #home"),
            ("Work/Meeting Notes.md", "# Meeting Notes - Q1 Review\n\n**Date:** 2026-03-15\n**Attendees:** Alice, Bob, Charlie\n\n## Key Decisions\n- Launch new feature by **April 15**\n- Hire two more engineers\n- Migrate to new cloud provider\n\nSee also: [[Project Ideas]] | [[Index]]\n\n#work #meetings"),
            ("Work/Project Roadmap.md", "# Project Roadmap 2026\n\n## Q1 - Foundation\n- [x] Set up CI/CD pipeline\n- [x] Design system components\n- [ ] API v2 migration\n\n## Q2 - Growth\n- [ ] Launch mobile app\n- [ ] Implement search\n\nConnects to [[Meeting Notes]] and [[Project Ideas]].\n\n> \"The best way to predict the future is to invent it.\" — Alan Kay\n\n```python\ndef velocity(points, sprints):\n    return sum(points) / len(sprints)\n```\n\n#work #roadmap"),
            ("Personal/Project Ideas.md", "# Project Ideas\n\n## App Concepts\n1. **Vomo** — Voice-first vault app [[Index]]\n2. **Habit Tracker** — Simple daily habits\n3. **Recipe Manager** — Organize recipes\n\n| Priority | Idea | Status |\n|----------|------|--------|\n| High | Vomo | In Progress |\n| Medium | Habit Tracker | Planned |\n| Low | Recipe Manager | Backlog |\n\n#personal #ideas"),
            ("Personal/Reading List.md", "# Reading List\n\n## Currently Reading\n- *Designing Data-Intensive Applications*\n- *The Pragmatic Programmer*\n\n## Finished\n- [x] *Atomic Habits* by James Clear\n- [x] *Deep Work* by Cal Newport\n\nRelated: [[Project Ideas]] | [[Meeting Notes]]\n\n#reading #books"),
            ("Daily Notes/2026-03-21.md", "# Daily Note — 2026-03-21\n\n## Today's Focus\n- Build the Vomo iOS app\n- Test iCloud integration\n- Review [[Project Roadmap]]\n\n## Tasks\n- [x] Create Xcode project\n- [x] Implement markdown rendering\n- [ ] Test on real device\n\n#daily #dev"),
        ]

        for (path, content) in sampleFiles {
            let fileURL = vaultDir.appendingPathComponent(path)
            try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        setDirectPath(vaultDir)
    }

    // MARK: - Two-Phase Vault Loading

    /// Debug helper to print vault location info
    func printVaultLocationInfo() {
        guard let vaultURL else {
            print("❌ No vault URL set")
            return
        }
        
        print("📁 Vault Location Debug Info:")
        print("   Display Path: \(vaultDisplayPath)")
        print("   Full Path: \(vaultURL.path)")
        print("   Is Local: \(isLocalPath)")
        print("   Absolute String: \(vaultURL.absoluteString)")
        
        // Check if it's in iCloud
        if vaultURL.path.contains("Mobile Documents") || vaultURL.path.contains("iCloud~") {
            print("   ☁️ This is an iCloud Drive location")
            
            // Try to find the container
            if let ubiquityURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
                print("   iCloud Container: \(ubiquityURL.path)")
            }
        } else {
            print("   💾 This is a local file location")
        }
        
        // List some actual file paths
        print("\n   First 5 file paths:")
        for (index, file) in files.prefix(5).enumerated() {
            print("   \(index + 1). \(file.url.path)")
        }
    }

    /// Phase 1: Load from local cache for instant display.
    /// Runs heavy builds off the main actor — call with `await`.
    func loadFromCache() async {
        guard let vaultURL, let cache else { return }
        await MainActor.run { syncState = .loadingCache }

        let cached = cache.loadAllCachedFiles(vaultRootURL: vaultURL)
        guard !cached.isEmpty else {
            await MainActor.run { syncState = .idle }
            return
        }

        // Heavy builds run here on the cooperative thread pool
        // (nonisolated async function called from @MainActor suspends the main actor)
        let tree = buildFolderTree(from: cached, rootURL: vaultURL)
        let graphData = buildGraph(from: cached)

        await MainActor.run {
            self.files = cached
            self.folderTree = tree
            self.graph = graphData
            self.syncState = .idle
        }

        // Print debug info
        printVaultLocationInfo()
    }

    /// Phase 2: Scan vault, download iCloud files, update cache
    func scanVault() async {
        guard let vaultURL else { return }

        if !isLocalPath {
            guard vaultURL.startAccessingSecurityScopedResource() else {
                print("Failed to access security-scoped resource")
                return
            }
        }
        defer { if !isLocalPath { vaultURL.stopAccessingSecurityScopedResource() } }

        await MainActor.run { syncState = .scanning }

        do {
            // Scan with progressive updates
            let (scannedFiles, pendingICloud) = try await scanFilesWithICloud(at: vaultURL) { progressFiles in
                // Build tree off main actor before switching to update UI
                let progressTree: VaultFolder? = progressFiles.count >= 100
                    ? self.buildFolderTree(from: progressFiles, rootURL: vaultURL)
                    : nil
                await MainActor.run {
                    self.files = progressFiles
                    if let progressTree {
                        self.folderTree = progressTree
                    }
                }
            }

            // Build tree/graph in background, then publish to main thread
            let tree = buildFolderTree(from: scannedFiles, rootURL: vaultURL)
            let graphData = buildGraph(from: scannedFiles)

            await MainActor.run {
                self.files = scannedFiles
                self.folderTree = tree
                self.graph = graphData
                self.lastSyncDate = Date()
                self.scanStatus = ""
            }

            // Start monitoring iCloud downloads if any are pending
            if !pendingICloud.isEmpty {
                await MainActor.run {
                    syncState = .downloading(completed: 0, total: pendingICloud.count)
                }
                downloadMonitor.startMonitoring(
                    files: pendingICloud,
                    vaultURL: vaultURL,
                    isLocalPath: isLocalPath,
                    onFileDownloaded: { [weak self] downloadedFile in
                        self?.handleFileDownloaded(downloadedFile, vaultURL: vaultURL)
                    },
                    onComplete: { [weak self] in
                        self?.syncState = .idle
                        self?.scanStatus = ""
                        self?.lastSyncDate = Date()
                    }
                )
            } else {
                // No iCloud files - complete immediately
                await MainActor.run {
                    self.scanStatus = ""
                    self.syncState = .idle
                }
            }

            // Cache all downloaded files in the background (runs after UI update)
            // This also loads content for files that weren't in cache
            Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                
                // Load content for files without it (not in cache)
                var updatedFiles = scannedFiles
                for (index, file) in updatedFiles.enumerated() {
                    if file.content == nil {
                        // Load content from disk
                        if let text = try? String(contentsOf: file.url, encoding: .utf8) {
                            let snippet = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                            updatedFiles[index] = VaultFile(
                                id: file.id,
                                url: file.url,
                                title: file.title,
                                relativePath: file.relativePath,
                                folderPath: file.folderPath,
                                createdDate: file.createdDate,
                                modifiedDate: file.modifiedDate,
                                contentSnippet: snippet,
                                content: text
                            )
                        }
                    }
                }
                
                // Cache all files and rebuild graph with full content
                self.cacheFiles(updatedFiles)
                
                // Rebuild graph with full content in background
                let newGraph = self.buildGraph(from: updatedFiles)
                await MainActor.run {
                    self.files = updatedFiles
                    self.graph = newGraph
                    print("✅ Background content loading complete. Graph rebuilt with \(newGraph.nodes.count) nodes")
                }
            }
        } catch {
            print("Scan failed: \(error)")
            DiagnosticLogger.shared.error("Vault", "Scan failed: \(error.localizedDescription)")
            await MainActor.run { syncState = .idle }
        }
    }

    // MARK: - Scanning with iCloud Awareness

    private func scanFilesWithICloud(
        at rootURL: URL,
        onProgress: (([VaultFile]) async -> Void)? = nil
    ) async throws -> ([VaultFile], [PendingFile]) {
        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        ) else { return ([], []) }

        var downloadedURLs: [URL] = []
        var pendingICloud: [PendingFile] = []
        var scannedCount = 0

        await MainActor.run { scanStatus = "Enumerating files in \(rootURL.lastPathComponent)..." }

        for case let url as URL in enumerator {
            let filename = url.lastPathComponent

            // Skip hidden directories like .obsidian, .trash, .git
            if filename.hasPrefix(".") && url.hasDirectoryPath {
                enumerator.skipDescendants()
                continue
            }

            // Detect .icloud placeholder files
            if filename.hasPrefix(".") && filename.hasSuffix(".icloud") {
                let inner = String(filename.dropFirst())
                let realName = String(inner.dropLast(".icloud".count))
                print("📦 Found iCloud placeholder: \(filename) -> \(realName)")
                if realName.lowercased().hasSuffix(".md") {
                    let realURL = url.deletingLastPathComponent().appendingPathComponent(realName)
                    let relativePath = realURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                    pendingICloud.append(PendingFile(icloudURL: url, realURL: realURL, relativePath: relativePath))
                    print("✅ Added to pending iCloud downloads: \(relativePath)")
                }
                continue
            }

            guard url.pathExtension.lowercased() == "md" else { continue }
            let values = try? url.resourceValues(forKeys: resourceKeys)
            guard values?.isRegularFile == true else { continue }
            downloadedURLs.append(url)

            scannedCount += 1
            if scannedCount % 20 == 0 {
                let local = downloadedURLs.count
                let icloud = pendingICloud.count
                await MainActor.run { scanStatus = "Found \(local) local, \(icloud) in iCloud..." }
            }
        }

        let localCount = downloadedURLs.count
        let icloudCount = pendingICloud.count
        print("📊 Scan complete: \(localCount) files locally, \(icloudCount) in iCloud")
        print("📁 Vault root path: \(rootURL.path)")
        if localCount > 0 {
            print("📄 Sample file path: \(downloadedURLs.first?.path ?? "none")")
        }
        await MainActor.run {
            scanStatus = "Found \(localCount) files locally, \(icloudCount) in iCloud"
        }

        // Build VaultFile array from already-downloaded files with progressive updates
        let totalToRead = downloadedURLs.count
        var result: [VaultFile] = []

        for (index, url) in downloadedURLs.enumerated() {
            let relativePath = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            let title = url.deletingPathExtension().lastPathComponent
            let folderPath: String
            if let lastSlash = relativePath.lastIndex(of: "/") {
                folderPath = String(relativePath[relativePath.startIndex..<lastSlash])
            } else {
                folderPath = ""
            }
            let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let modDate = resourceValues?.contentModificationDate ?? Date()
            let createDate = resourceValues?.creationDate ?? modDate

            // OPTIMIZED: Only read from cache, don't load from disk yet
            // Content will be loaded on-demand when needed (for search or viewing)
            var content: String?
            var snippet = ""

            if let cache, cache.isCached(relativePath: relativePath, modifiedDate: modDate) {
                // Use cached content if available
                content = cache.readCachedContent(relativePath: relativePath)
                snippet = content.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) } ?? ""
            } else {
                // Don't read file content during initial scan - load on demand
                content = nil
                snippet = ""
            }

            result.append(VaultFile(
                id: relativePath,
                url: url,
                title: title,
                relativePath: relativePath,
                folderPath: folderPath,
                createdDate: createDate,
                modifiedDate: modDate,
                contentSnippet: snippet,
                content: content
            ))

            // Progressive update every 50 files
            if (index + 1) % 50 == 0 || (index + 1) == totalToRead {
                await MainActor.run {
                    scanStatus = "Indexing: \(index + 1)/\(totalToRead)..."
                }
                
                // Call progress callback with sorted partial results
                if let onProgress, !result.isEmpty {
                    let sortedPartial = result.sorted { $0.modifiedDate > $1.modifiedDate }
                    print("📤 Progressive update: sending \(sortedPartial.count) files to UI")
                    await onProgress(sortedPartial)
                }
            }
        }

        await MainActor.run {
            scanStatus = "Read \(totalToRead) files, building index..."
        }

        return (result.sorted { $0.modifiedDate > $1.modifiedDate }, pendingICloud)
    }

    // MARK: - Handle Downloaded iCloud File

    private func handleFileDownloaded(_ pending: PendingFile, vaultURL: URL) {
        guard let text = try? String(contentsOf: pending.realURL, encoding: .utf8) else { return }
        let title = pending.realURL.deletingPathExtension().lastPathComponent
        let folderPath: String
        if let lastSlash = pending.relativePath.lastIndex(of: "/") {
            folderPath = String(pending.relativePath[pending.relativePath.startIndex..<lastSlash])
        } else {
            folderPath = ""
        }
        let resourceValues = try? pending.realURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let modDate = resourceValues?.contentModificationDate ?? Date()
        let createDate = resourceValues?.creationDate ?? modDate
        let snippet = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))

        let file = VaultFile(
            id: pending.relativePath,
            url: pending.realURL,
            title: title,
            relativePath: pending.relativePath,
            folderPath: folderPath,
            createdDate: createDate,
            modifiedDate: modDate,
            contentSnippet: snippet,
            content: text
        )

        // Cache the downloaded file
        cache?.cacheFile(relativePath: pending.relativePath, content: text, metadata: CachedFileMetadata(
            relativePath: pending.relativePath,
            title: title,
            folderPath: folderPath,
            createdDate: createDate,
            modifiedDate: modDate,
            contentSnippet: snippet
        ))
        cache?.flushManifest()

        // Update file list on main thread, rebuild tree/graph in background
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.files.append(file)
            self.files.sort { $0.modifiedDate > $1.modifiedDate }
            self.syncState = .downloading(
                completed: self.downloadMonitor.downloadedFiles,
                total: self.downloadMonitor.totalFiles
            )
            // Rebuild tree/graph in background to avoid blocking UI during rapid downloads
            let currentFiles = self.files
            if let vaultURL = self.vaultURL {
                Task.detached(priority: .utility) { [weak self] in
                    guard let self else { return }
                    let tree = self.buildFolderTree(from: currentFiles, rootURL: vaultURL)
                    let graphData = self.buildGraph(from: currentFiles)
                    await MainActor.run {
                        self.folderTree = tree
                        self.graph = graphData
                    }
                }
            }
        }
    }

    // MARK: - Caching

    private func cacheFiles(_ files: [VaultFile]) {
        guard let cache else { return }
        for file in files {
            guard let content = file.content else { continue }
            cache.cacheFile(
                relativePath: file.id,
                content: content,
                metadata: CachedFileMetadata(
                    relativePath: file.id,
                    title: file.title,
                    folderPath: file.folderPath,
                    createdDate: file.createdDate,
                    modifiedDate: file.modifiedDate,
                    contentSnippet: file.contentSnippet
                )
            )
        }
        cache.pruneDeletedFiles(currentPaths: Set(files.map(\.id)))
        cache.flushManifest()  // Write manifest once after all files
    }

    // MARK: - Background Sync

    func startPeriodicSync(interval: TimeInterval = 60) {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                await self.performIncrementalSync()
            }
        }
    }

    func stopPeriodicSync() {
        syncTask?.cancel()
        syncTask = nil
        downloadMonitor.stopMonitoring()
    }

    private func performIncrementalSync() async {
        guard let vaultURL else { return }
        if !isLocalPath {
            guard vaultURL.startAccessingSecurityScopedResource() else { return }
        }
        defer { if !isLocalPath { vaultURL.stopAccessingSecurityScopedResource() } }

        await MainActor.run { syncState = .syncing }

        do {
            let (scannedFiles, pendingICloud) = try await scanFilesWithICloud(at: vaultURL)

            // Build tree/graph in background before publishing to main
            let tree = buildFolderTree(from: scannedFiles, rootURL: vaultURL)
            let graphData = buildGraph(from: scannedFiles)

            await MainActor.run {
                self.files = scannedFiles
                self.folderTree = tree
                self.graph = graphData
                self.lastSyncDate = Date()
                self.syncState = .idle
            }

            cacheFiles(scannedFiles)

            // Download any new iCloud files
            if !pendingICloud.isEmpty {
                downloadMonitor.startMonitoring(
                    files: pendingICloud,
                    vaultURL: vaultURL,
                    isLocalPath: isLocalPath,
                    onFileDownloaded: { [weak self] file in
                        self?.handleFileDownloaded(file, vaultURL: vaultURL)
                    },
                    onComplete: { [weak self] in
                        self?.syncState = .idle
                        self?.lastSyncDate = Date()
                    }
                )
            }
        } catch {
            await MainActor.run { syncState = .idle }
        }
    }

    // MARK: - Folder Tree

    /// Exposed for testing. Use `buildFolderTree` internally.
    func testBuildFolderTree(from files: [VaultFile], rootURL: URL) -> VaultFolder {
        buildFolderTree(from: files, rootURL: rootURL)
    }

    private func buildFolderTree(from files: [VaultFile], rootURL: URL) -> VaultFolder {
        let root = VaultFolder(id: "", name: rootURL.lastPathComponent, url: rootURL, children: [], files: [])
        var folderMap: [String: VaultFolder] = ["": root]

        for file in files {
            let components = file.folderPath.split(separator: "/").map(String.init)
            var currentPath = ""
            var parentPath = ""
            for component in components {
                parentPath = currentPath
                currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
                if folderMap[currentPath] == nil {
                    let folderURL = rootURL.appendingPathComponent(currentPath)
                    let folder = VaultFolder(id: currentPath, name: component, url: folderURL, children: [], files: [])
                    folderMap[currentPath] = folder
                    folderMap[parentPath]?.children.append(folder)
                }
            }
        }

        for file in files {
            folderMap[file.folderPath]?.files.append(file)
        }

        func buildFolder(_ path: String) -> VaultFolder {
            guard var folder = folderMap[path] else { return root }
            folder.children = folder.children.map { buildFolder($0.id) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            folder.files = folder.files
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return folder
        }

        return buildFolder("")
    }

    // MARK: - Graph Building

    /// Exposed for testing.
    func testBuildGraph(from files: [VaultFile]) -> VaultGraph {
        buildGraph(from: files)
    }

    private func buildGraph(from files: [VaultFile]) -> VaultGraph {
        let wikiLinkPattern = /\[\[([^\]|]+)(?:\|[^\]]*)?\]\]/
        var linkMap: [String: Set<String>] = [:]
        let filesByTitle: [String: VaultFile] = Dictionary(
            files.map { ($0.title.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let filesByPath: [String: VaultFile] = Dictionary(
            files.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for file in files {
            guard let content = file.content else { continue }
            let matches = content.matches(of: wikiLinkPattern)
            var targets: Set<String> = []
            for match in matches {
                var linkText = String(match.1).trimmingCharacters(in: .whitespaces)
                // Strip heading anchor: [[Note#Heading]] → "Note"
                if let hashIndex = linkText.firstIndex(of: "#") {
                    linkText = String(linkText[linkText.startIndex..<hashIndex])
                }
                guard !linkText.isEmpty else { continue }
                if let target = filesByTitle[linkText.lowercased()] {
                    targets.insert(target.id)
                } else if let target = filesByPath[linkText] {
                    targets.insert(target.id)
                } else if let target = filesByPath[linkText + ".md"] {
                    targets.insert(target.id)
                } else if let target = files.first(where: { $0.id.lowercased().hasSuffix("/\(linkText.lowercased()).md") }) {
                    targets.insert(target.id)
                }
            }
            if !targets.isEmpty {
                linkMap[file.id] = targets
            }
        }

        var connectionCounts: [String: Int] = [:]
        for (source, targets) in linkMap {
            connectionCounts[source, default: 0] += targets.count
            for target in targets {
                connectionCounts[target, default: 0] += 1
            }
        }

        let connectedIDs = Set(connectionCounts.keys)
        let nodes = files.filter { connectedIDs.contains($0.id) }.map { file in
            let topFolder = file.folderPath.split(separator: "/").first.map(String.init) ?? ""
            return GraphNode(
                id: file.id,
                title: file.title,
                folder: topFolder,
                connectionCount: connectionCounts[file.id] ?? 0
            )
        }

        var edges: [GraphEdge] = []
        for (source, targets) in linkMap {
            for target in targets {
                if connectedIDs.contains(source) && connectedIDs.contains(target) {
                    edges.append(GraphEdge(source: source, target: target))
                }
            }
        }

        return VaultGraph(nodes: nodes, edges: edges)
    }

    /// Rebuild graph lazily — called when voice search graph view is opened
    func rebuildGraphIfStale() {
        guard graphStale else { return }
        graph = buildGraph(from: files)
        graphStale = false
    }

    // MARK: - Wiki Link Resolution

    func resolveWikiLink(_ name: String) -> VaultFile? {
        // Strip heading anchor: "Note#Heading" → "Note"
        var cleanName = name
        if let hashIndex = cleanName.firstIndex(of: "#") {
            cleanName = String(cleanName[cleanName.startIndex..<hashIndex])
        }
        guard !cleanName.isEmpty else { return nil }
        let lowered = cleanName.lowercased()
        if let file = files.first(where: { $0.title.lowercased() == lowered }) {
            return file
        }
        if let file = files.first(where: { $0.id.lowercased() == lowered || $0.id.lowercased() == lowered + ".md" }) {
            return file
        }
        if let file = files.first(where: { $0.id.lowercased().hasSuffix("/\(lowered).md") }) {
            return file
        }
        return nil
    }

    // MARK: - File Content

    func loadContent(for file: VaultFile) -> String {
        // Try cache first
        if let cached = cache?.readCachedContent(relativePath: file.id) {
            return cached
        }
        // Fall back to reading from iCloud/disk
        if isLocalPath {
            return (try? String(contentsOf: file.url, encoding: .utf8)) ?? file.content ?? ""
        }
        guard let vaultURL else { return file.content ?? "" }
        guard vaultURL.startAccessingSecurityScopedResource() else {
            return file.content ?? ""
        }
        defer { vaultURL.stopAccessingSecurityScopedResource() }

        if let text = try? String(contentsOf: file.url, encoding: .utf8) {
            // Cache for next time
            cache?.cacheFile(relativePath: file.id, content: text, metadata: CachedFileMetadata(
                relativePath: file.id,
                title: file.title,
                folderPath: file.folderPath,
                createdDate: file.createdDate,
                modifiedDate: file.modifiedDate,
                contentSnippet: file.contentSnippet
            ))
            return text
        }
        return file.content ?? ""
    }

    // MARK: - Recent Files

    func markAsRecent(_ file: VaultFile) {
        var ids = recentFileIDs
        ids.removeAll { $0 == file.id }
        ids.insert(file.id, at: 0)
        if ids.count > maxRecentFiles {
            ids = Array(ids.prefix(maxRecentFiles))
        }
        recentFileIDs = ids
    }

    // MARK: - File Creation

    /// Create a new markdown file in the vault and add it to the in-memory file list.
    /// Returns the created VaultFile, or nil on failure.
    @discardableResult
    func createFile(name: String, folderPath: String, content: String) -> VaultFile? {
        guard let vaultURL else { return nil }

        let needsAccess = !isLocalPath
        if needsAccess {
            guard vaultURL.startAccessingSecurityScopedResource() else { return nil }
        }
        defer { if needsAccess { vaultURL.stopAccessingSecurityScopedResource() } }

        // Build target directory
        let folderURL = folderPath.isEmpty
            ? vaultURL
            : vaultURL.appendingPathComponent(folderPath)

        // Ensure folder exists
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        // Sanitize filename
        let sanitized = name.hasSuffix(".md") ? name : name + ".md"
        let fileURL = folderURL.appendingPathComponent(sanitized)

        // Don't overwrite existing files
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to create file: \(error)")
            return nil
        }

        let relativePath = folderPath.isEmpty ? sanitized : "\(folderPath)/\(sanitized)"
        let title = fileURL.deletingPathExtension().lastPathComponent
        let now = Date()
        let snippet = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))

        let file = VaultFile(
            id: relativePath,
            url: fileURL,
            title: title,
            relativePath: relativePath,
            folderPath: folderPath,
            createdDate: now,
            modifiedDate: now,
            contentSnippet: snippet,
            content: content
        )

        // Update in-memory state
        files.insert(file, at: 0)
        folderTree = buildFolderTree(from: files, rootURL: vaultURL)
        graphStale = true

        // Cache
        cache?.cacheFile(relativePath: relativePath, content: content, metadata: CachedFileMetadata(
            relativePath: relativePath,
            title: title,
            folderPath: folderPath,
            createdDate: now,
            modifiedDate: now,
            contentSnippet: snippet
        ))
        cache?.flushManifest()

        // Mark newly created file as recent
        markAsRecent(file)

        return file
    }

    /// Rename a file (changes the filename, keeps it in the same folder).
    /// Returns the updated VaultFile, or nil on failure.
    @discardableResult
    func renameFile(_ file: VaultFile, to newName: String) -> VaultFile? {
        guard let vaultURL else { return nil }
        let sanitized = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return nil }

        let needsAccess = !isLocalPath
        if needsAccess {
            guard vaultURL.startAccessingSecurityScopedResource() else { return nil }
        }
        defer { if needsAccess { vaultURL.stopAccessingSecurityScopedResource() } }

        let newFileName = sanitized.hasSuffix(".md") ? sanitized : "\(sanitized).md"
        let destURL = file.url.deletingLastPathComponent().appendingPathComponent(newFileName)

        // Don't overwrite existing files
        guard !FileManager.default.fileExists(atPath: destURL.path) else { return nil }

        do {
            try FileManager.default.moveItem(at: file.url, to: destURL)
        } catch {
            print("Failed to rename file: \(error)")
            return nil
        }

        let newRelativePath = file.folderPath.isEmpty ? newFileName : "\(file.folderPath)/\(newFileName)"
        let newTitle = sanitized.hasSuffix(".md") ? String(sanitized.dropLast(3)) : sanitized
        let renamed = VaultFile(
            id: newRelativePath,
            url: destURL,
            title: newTitle,
            relativePath: newRelativePath,
            folderPath: file.folderPath,
            createdDate: file.createdDate,
            modifiedDate: file.modifiedDate,
            contentSnippet: file.contentSnippet,
            content: file.content
        )

        if let idx = files.firstIndex(where: { $0.id == file.id }) {
            files[idx] = renamed
        }
        folderTree = buildFolderTree(from: files, rootURL: vaultURL)
        graphStale = true

        cache?.pruneDeletedFiles(currentPaths: Set(files.map(\.id)))
        if let content = file.content ?? (try? String(contentsOf: destURL, encoding: .utf8)) {
            cache?.cacheFile(relativePath: newRelativePath, content: content, metadata: CachedFileMetadata(
                relativePath: newRelativePath,
                title: newTitle,
                folderPath: file.folderPath,
                createdDate: file.createdDate,
                modifiedDate: file.modifiedDate,
                contentSnippet: file.contentSnippet
            ))
        }
        cache?.flushManifest()

        return renamed
    }

    /// Move an existing file to a different folder within the vault.
    /// Returns the updated VaultFile, or nil on failure.
    @discardableResult
    func moveFile(_ file: VaultFile, toFolder destinationFolder: String) -> VaultFile? {
        guard let vaultURL else { return nil }

        let needsAccess = !isLocalPath
        if needsAccess {
            guard vaultURL.startAccessingSecurityScopedResource() else { return nil }
        }
        defer { if needsAccess { vaultURL.stopAccessingSecurityScopedResource() } }

        let fileName = file.url.lastPathComponent
        let destFolderURL = destinationFolder.isEmpty
            ? vaultURL
            : vaultURL.appendingPathComponent(destinationFolder)
        let destFileURL = destFolderURL.appendingPathComponent(fileName)

        // Don't overwrite existing files
        guard !FileManager.default.fileExists(atPath: destFileURL.path) else { return nil }

        // Ensure destination folder exists
        try? FileManager.default.createDirectory(at: destFolderURL, withIntermediateDirectories: true)

        do {
            try FileManager.default.moveItem(at: file.url, to: destFileURL)
        } catch {
            print("Failed to move file: \(error)")
            return nil
        }

        let newRelativePath = destinationFolder.isEmpty ? fileName : "\(destinationFolder)/\(fileName)"
        let moved = VaultFile(
            id: newRelativePath,
            url: destFileURL,
            title: file.title,
            relativePath: newRelativePath,
            folderPath: destinationFolder,
            createdDate: file.createdDate,
            modifiedDate: file.modifiedDate,
            contentSnippet: file.contentSnippet,
            content: file.content
        )

        // Update in-memory state
        if let idx = files.firstIndex(where: { $0.id == file.id }) {
            files[idx] = moved
        }
        folderTree = buildFolderTree(from: files, rootURL: vaultURL)
        graphStale = true

        // Update cache: prune old path, add new one
        cache?.pruneDeletedFiles(currentPaths: Set(files.map(\.id)))
        if let content = file.content ?? (try? String(contentsOf: destFileURL, encoding: .utf8)) {
            cache?.cacheFile(relativePath: newRelativePath, content: content, metadata: CachedFileMetadata(
                relativePath: newRelativePath,
                title: file.title,
                folderPath: destinationFolder,
                createdDate: file.createdDate,
                modifiedDate: file.modifiedDate,
                contentSnippet: file.contentSnippet
            ))
        }
        cache?.flushManifest()

        return moved
    }

    /// Update the content of an existing file on disk and refresh in-memory state.
    func updateFileContent(_ file: VaultFile, newContent: String) {
        guard let vaultURL else { return }

        let needsAccess = !isLocalPath
        if needsAccess {
            guard vaultURL.startAccessingSecurityScopedResource() else { return }
        }
        defer { if needsAccess { vaultURL.stopAccessingSecurityScopedResource() } }

        do {
            try newContent.write(to: file.url, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to update file: \(error)")
            return
        }

        let now = Date()
        let snippet = String(newContent.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let updated = VaultFile(
            id: file.id,
            url: file.url,
            title: file.title,
            relativePath: file.relativePath,
            folderPath: file.folderPath,
            createdDate: file.createdDate,
            modifiedDate: now,
            contentSnippet: snippet,
            content: newContent
        )

        if let idx = files.firstIndex(where: { $0.id == file.id }) {
            files[idx] = updated
        }

        cache?.cacheFile(relativePath: file.id, content: newContent, metadata: CachedFileMetadata(
            relativePath: file.id,
            title: file.title,
            folderPath: file.folderPath,
            createdDate: file.createdDate,
            modifiedDate: now,
            contentSnippet: snippet
        ))
        cache?.flushManifest()

        // Mark updated file as recent
        markAsRecent(updated)
    }

    /// Detect the best diary-like folder in the vault, or nil if none found.
    func detectDiaryFolder() -> String? {
        let diaryNames = Set(["daily notes", "diary", "journal", "daily", "dailies"])
        // Check top-level folders first
        if let tree = folderTree {
            for child in tree.children {
                if diaryNames.contains(child.name.lowercased()) {
                    return child.id
                }
            }
        }
        // Fallback: look at file paths
        for file in files {
            let folder = file.folderPath.split(separator: "/").last.map(String.init) ?? ""
            if diaryNames.contains(folder.lowercased()) {
                return file.folderPath
            }
        }
        return nil
    }

    /// Generate today's diary filename (YYYY-MM-DD.md)
    func todayDiaryFilename() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date()) + ".md"
    }

    // MARK: - Reset

    func resetVault() {
        stopPeriodicSync()
        cache?.clearCache()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: vaultPathKey)
        clearEmbeddingsBookmark()
        isLocalPath = false
        vaultURL = nil
        files = []
        folderTree = nil
        graph = .empty
        graphStale = false
        cache = nil
    }
}

// MARK: - Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
