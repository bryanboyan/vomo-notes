import SwiftUI

/// View mode toggle for the top panel
enum VoiceSearchViewMode: String, CaseIterable {
    case list = "List"
    case graph = "Graph"
}

/// Full-screen split layout for voice-driven file search.
/// Top panel (55%): found files / graph view (toggleable).
/// Bottom panel (45%): voice console with transcript and controls.
struct AgentVoiceSearchView: View {
    @Environment(VaultManager.self) var vault
    @Environment(DataviewEngine.self) var dataview
    @Environment(\.dismiss) private var dismiss
    @Binding var navigationPath: [VaultFile]
    let service: AgentVoiceService

    @State private var showApiKeyPrompt = false
    @State private var apiKeyInput = ""
    @State private var hasStartedSession = false
    @State private var metadataCache: [String: FileMetadata] = [:]
    @State private var viewMode: VoiceSearchViewMode = .list

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Top: File panel or graph (toggleable)
                ZStack {
                    switch viewMode {
                    case .list:
                        filePanel
                    case .graph:
                        graphPanel
                    }
                }
                .frame(height: geo.size.height * 0.55)

                Divider()

                // Bottom: Voice console (fixed)
                AgentVoiceConsole(service: service) {
                    service.disconnect()
                    dismiss()
                }
                .frame(height: geo.size.height * 0.45)
            }
        }
        .navigationTitle("Voice Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $viewMode) {
                    ForEach(VoiceSearchViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
        }
        .onAppear {
            if !hasStartedSession {
                startSession()
                hasStartedSession = true
            }
        }
        .alert("Grok API Key", isPresented: $showApiKeyPrompt) {
            SecureField("xai-...", text: $apiKeyInput)
            Button("Save") {
                if !apiKeyInput.isEmpty {
                    _ = APIKeychain.save(vendor: VoiceSettings.shared.realtimeVendor.rawValue, key: apiKeyInput)
                    startSession()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter your xAI API key to use voice search.")
        }
    }

    // MARK: - Graph Panel

    @ViewBuilder
    private var graphPanel: some View {
        VoiceGraphWebView(
            graphManager: service.graphManager,
            onNodeTap: { nodeId, label in
                // When a graph node is tapped, search for it
                if let file = vault.files.first(where: {
                    $0.title.localizedCaseInsensitiveContains(label)
                }) {
                    vault.markAsRecent(file)
                    navigationPath.append(file)
                }
            },
            onDeselect: { }
        )
    }

    // MARK: - File Panel

    @ViewBuilder
    private var filePanel: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // AI-found files
                if !service.foundFiles.isEmpty {
                    sectionHeader("Found", count: service.foundFiles.count)

                    ForEach(service.foundFiles) { found in
                        AgentFileCard(foundFile: found, metadata: metadataCache[found.file.id]) {
                            vault.markAsRecent(found.file)
                            navigationPath.append(found.file)
                        }
                        Divider().padding(.leading, 64)
                    }
                }

                // Recent files below
                let recents = vault.recentFiles
                if !recents.isEmpty {
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
                        Divider().padding(.leading)
                    }
                }

                if service.foundFiles.isEmpty && recents.isEmpty {
                    ContentUnavailableView(
                        "No Files Yet",
                        systemImage: "mic.badge.plus",
                        description: Text("Speak to search your vault")
                    )
                    .padding(.top, 40)
                }
            }
            .padding(.bottom, 16)
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
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Session

    private func startSession() {
        guard let apiKey = APIKeychain.load(vendor: VoiceSettings.shared.realtimeVendor.rawValue) else {
            showApiKeyPrompt = true
            return
        }

        // Wire up tool execution
        service.onToolCall = { [vault] name, args in
            await executeToolCall(vault: vault, name: name, args: args)
        }

        service.connect(apiKey: apiKey, fileCount: vault.files.count, vaultURL: vault.vaultURL)
    }

    /// Execute a tool call from the AI agent
    @MainActor
    private func executeToolCall(vault: VaultManager, name: String, args: [String: Any]) async -> String {
        switch name {
        case "search_vault":
            return executeSearchVault(vault: vault, args: args)

        case "search_vault_by_date":
            return executeSearchByDate(vault: vault, args: args)

        case "search_vault_by_attribute":
            return executeSearchByAttribute(vault: vault, args: args)

        case "search_vault_combined":
            return executeSearchCombined(vault: vault, args: args)

        case "extract_entities":
            return executeExtractEntities(args: args)

        case "open_file":
            return executeOpenFile(vault: vault, args: args)

        case "read_file_content":
            return executeReadFileContent(vault: vault, args: args)

        case "create_doc":
            return executeCreateDoc(vault: vault, args: args)

        case "move_file":
            return executeMoveFile(vault: vault, args: args)

        default:
            return "{\"error\": \"unknown_tool\"}"
        }
    }

    @MainActor
    private func executeSearchVault(vault: VaultManager, args: [String: Any]) -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "{\"results\": [], \"message\": \"No query provided\"}"
        }

        // FTS5 ranked search — up to 50 results
        FileAccessLogger.shared.log(.agent, summary: "\"\(query)\"")
        print("🔍 [SEARCH] FTS5 query: \"\(query)\" (vault has \(vault.files.count) files)")
        let rankedPaths = dataview.searchNotes(query: query, limit: 50)
        print("🔍 [SEARCH] FTS5 returned \(rankedPaths.count) paths: \(rankedPaths.prefix(5))")
        let filesByPath = Dictionary(vault.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var results = rankedPaths.compactMap { filesByPath[$0] }
        print("🔍 [SEARCH] Resolved to \(results.count) files")

        // Fallback to substring if FTS5 returns nothing
        if results.isEmpty {
            let lowered = query.lowercased()
            results = Array(vault.files.filter { file in
                file.title.localizedCaseInsensitiveContains(lowered) ||
                file.contentSnippet.localizedCaseInsensitiveContains(lowered) ||
                (file.content?.localizedCaseInsensitiveContains(lowered) ?? false)
            }.sorted { a, b in
                let aTitle = a.title.localizedCaseInsensitiveContains(lowered)
                let bTitle = b.title.localizedCaseInsensitiveContains(lowered)
                if aTitle != bTitle { return aTitle }
                return a.modifiedDate > b.modifiedDate
            }.prefix(50))
        }

        if results.isEmpty {
            print("🔍 [SEARCH] No results for \"\(query)\"")
            return "{\"results\": [], \"message\": \"No notes found matching '\(query)'\"}"
        }
        print("🔍 [SEARCH] Final \(results.count) results: \(results.map { $0.title })")

        return buildSearchResponse(vault: vault, results: results, reason: "Matched '\(query)'", queryForSnippet: query.lowercased())
    }

    @MainActor
    private func executeSearchByDate(vault: VaultManager, args: [String: Any]) -> String {
        guard let startStr = args["start_date"] as? String,
              let endStr = args["end_date"] as? String else {
            return "{\"results\": [], \"message\": \"Missing start_date or end_date\"}"
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let startDate = fmt.date(from: startStr),
              let endDate = fmt.date(from: endStr) else {
            return "{\"results\": [], \"message\": \"Invalid date format. Use YYYY-MM-DD.\"}"
        }

        print("📅 [DATE SEARCH] \(startStr) → \(endStr)")
        let paths = dataview.searchByDateRange(from: startDate, to: endDate)
        return buildFoundFilesResponse(vault: vault, paths: paths, reason: "Date: \(startStr) to \(endStr)")
    }

    @MainActor
    private func executeSearchByAttribute(vault: VaultManager, args: [String: Any]) -> String {
        guard let attribute = args["attribute"] as? String, !attribute.isEmpty else {
            return "{\"results\": [], \"message\": \"No attribute provided\"}"
        }
        guard let value = args["value"] as? String, !value.isEmpty else {
            return "{\"results\": [], \"message\": \"No value provided\"}"
        }

        print("🔎 [ATTR SEARCH] \(attribute)=\(value)")
        let paths = dataview.searchByAttribute(key: attribute, value: value)
        return buildFoundFilesResponse(vault: vault, paths: paths, reason: "\(attribute): \(value)")
    }

    /// Shared helper to convert search result paths into found files + JSON response
    @MainActor
    private func buildFoundFilesResponse(vault: VaultManager, paths: [String], reason: String) -> String {
        let filesByPath = Dictionary(vault.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let results = paths.compactMap { filesByPath[$0] }

        if results.isEmpty {
            return "{\"results\": [], \"message\": \"No notes found\"}"
        }

        return buildSearchResponse(vault: vault, results: results, reason: reason, queryForSnippet: nil)
    }

    /// Unified search response builder with optional auto-load content.
    /// Adds found files to UI, fetches metadata, and optionally loads note body content.
    @MainActor
    private func buildSearchResponse(vault: VaultManager, results: [VaultFile], reason: String, queryForSnippet: String?) -> String {
        let autoLoad = VoiceSettings.shared.autoLoadNoteContent

        // Fetch metadata
        let meta = dataview.fetchMetadata(for: results)
        metadataCache.merge(meta) { _, new in new }

        // Add to UI
        for file in results {
            let snippet = queryForSnippet.map { extractSnippet(from: file, query: $0) } ?? file.contentSnippet
            service.addFoundFile(file, reason: reason, snippet: snippet)
        }

        // Build JSON — include content when auto-load is enabled (up to 50 notes)
        let resultDicts: [[String: Any]] = results.prefix(50).map { file in
            var dict: [String: Any] = [
                "title": file.title,
                "path": file.relativePath,
                "snippet": queryForSnippet.map { extractSnippet(from: file, query: $0) } ?? String(file.contentSnippet.prefix(100))
            ]
            if let m = meta[file.id] {
                if let d = m.dateDisplay { dict["date"] = d }
                if let mood = m.mood { dict["mood"] = mood }
                if !m.tags.isEmpty { dict["tags"] = m.tags }
            }

            // Auto-load: include truncated body content so the model can reference it
            if autoLoad {
                let fullContent = vault.loadContent(for: file)
                if !fullContent.isEmpty {
                    let (_, body) = MarkdownParser.extractFrontmatter(fullContent)
                    let truncated = body.count > 2000 ? String(body.prefix(2000)) + "\n[...truncated]" : body
                    dict["search_content"] = truncated
                }
            }

            return dict
        }

        var response: [String: Any] = ["results": resultDicts, "count": results.count]
        if autoLoad {
            response["content_loaded"] = true
        }

        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{\"results\": [], \"error\": \"serialization_error\"}"
        }
        return jsonString
    }

    /// Combined multi-criteria search: text + date range + attributes in one call
    @MainActor
    private func executeSearchCombined(vault: VaultManager, args: [String: Any]) -> String {
        let query = args["query"] as? String
        let startStr = args["start_date"] as? String
        let endStr = args["end_date"] as? String
        let attributes = args["attributes"] as? [String: String]

        // Validate at least one criterion
        let hasQuery = query != nil && !query!.isEmpty
        let hasDateRange = startStr != nil && endStr != nil
        let hasAttributes = attributes != nil && !attributes!.isEmpty
        guard hasQuery || hasDateRange || hasAttributes else {
            return "{\"results\": [], \"message\": \"Provide at least one of: query, date range, or attributes\"}"
        }

        FileAccessLogger.shared.log(.agent, summary: "combined search")
        let filesByPath = Dictionary(vault.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Start with all paths or text search results
        var candidatePaths: Set<String>?

        // 1. Text search
        if hasQuery {
            let textPaths = dataview.searchNotes(query: query!, limit: 50)
            candidatePaths = Set(textPaths)
            print("🔍 [COMBINED] Text '\(query!)' → \(textPaths.count) results")
        }

        // 2. Date range filter
        if hasDateRange {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            if let startDate = fmt.date(from: startStr!),
               let endDate = fmt.date(from: endStr!) {
                let datePaths = Set(dataview.searchByDateRange(from: startDate, to: endDate, limit: 200))
                print("🔍 [COMBINED] Date \(startStr!) → \(endStr!) → \(datePaths.count) results")
                if let existing = candidatePaths {
                    candidatePaths = existing.intersection(datePaths)
                } else {
                    candidatePaths = datePaths
                }
            }
        }

        // 3. Attribute filters
        if let attributes, hasAttributes {
            for (key, value) in attributes {
                let attrPaths = Set(dataview.searchByAttribute(key: key, value: value, limit: 200))
                print("🔍 [COMBINED] Attr \(key)=\(value) → \(attrPaths.count) results")
                if let existing = candidatePaths {
                    candidatePaths = existing.intersection(attrPaths)
                } else {
                    candidatePaths = attrPaths
                }
            }
        }

        guard let finalPaths = candidatePaths, !finalPaths.isEmpty else {
            return "{\"results\": [], \"message\": \"No notes matched all criteria\"}"
        }

        // Resolve to files, preserving text-search ranking if available
        let results: [VaultFile]
        if hasQuery {
            // Keep FTS5 ranking order for text matches
            let rankedPaths = dataview.searchNotes(query: query!, limit: 50)
            results = rankedPaths.filter { finalPaths.contains($0) }.compactMap { filesByPath[$0] }
        } else {
            // Sort by modified date when no text ranking
            results = Array(finalPaths.compactMap { filesByPath[$0] }
                .sorted { $0.modifiedDate > $1.modifiedDate }
                .prefix(50))
        }

        print("🔍 [COMBINED] Final: \(results.count) results")
        let reason = [
            hasQuery ? "query: '\(query!)'" : nil,
            hasDateRange ? "date: \(startStr!) to \(endStr!)" : nil,
            hasAttributes ? "attributes: \(attributes!.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))" : nil
        ].compactMap { $0 }.joined(separator: " + ")

        return buildSearchResponse(vault: vault, results: results, reason: reason, queryForSnippet: query?.lowercased())
    }

    @MainActor
    private func executeOpenFile(vault: VaultManager, args: [String: Any]) -> String {
        guard let filename = args["filename"] as? String else {
            print("📂 [OPEN] Error: no filename in args")
            return "{\"error\": \"no_filename\"}"
        }

        print("📂 [OPEN] Looking for: \"\(filename)\"")
        guard let file = vault.resolveWikiLink(filename) else {
            print("📂 [OPEN] Not found: \"\(filename)\"")
            return "{\"error\": \"not_found\", \"message\": \"Could not find a file called '\(filename)'\"}"
        }

        print("📂 [OPEN] Found: \(file.title) at \(file.relativePath)")
        let snippet = file.contentSnippet
        service.addFoundFile(file, reason: "Opened by assistant", snippet: snippet, highlighted: true)
        vault.markAsRecent(file)
        navigationPath.append(file)
        return "{\"status\": \"opened\", \"title\": \"\(file.title)\", \"path\": \"\(file.relativePath)\"}"
    }

    @MainActor
    private func executeReadFileContent(vault: VaultManager, args: [String: Any]) -> String {
        guard let filename = args["filename"] as? String else {
            print("📖 [READ] Error: no filename in args")
            return "{\"error\": \"no_filename\"}"
        }

        print("📖 [READ] Looking for: \"\(filename)\"")
        guard let file = vault.resolveWikiLink(filename) else {
            print("📖 [READ] Not found: \"\(filename)\"")
            return "{\"error\": \"not_found\", \"message\": \"Could not find a file called '\(filename)'\"}"
        }

        let fullContent = vault.loadContent(for: file)
        print("📖 [READ] Loaded \(file.title): \(fullContent.count) chars")
        if fullContent.isEmpty {
            print("📖 [READ] Empty content (iCloud pending?)")
            return "{\"error\": \"icloud_pending\", \"message\": \"That file hasn't downloaded from iCloud yet.\"}"
        }

        // Strip frontmatter
        let (_, body) = MarkdownParser.extractFrontmatter(fullContent)

        // Truncate to ~4000 chars
        let truncated = body.count > 4000 ? String(body.prefix(4000)) + "\n[...truncated]" : body

        // Also add to found files if not already there
        service.addFoundFile(file, reason: "Read by assistant", snippet: String(body.prefix(100)))

        guard let data = try? JSONSerialization.data(withJSONObject: [
            "title": file.title,
            "path": file.relativePath,
            "content": truncated
        ] as [String: String]),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{\"error\": \"serialization_error\"}"
        }
        return jsonString
    }

    @MainActor
    private func executeCreateDoc(vault: VaultManager, args: [String: Any]) -> String {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return "{\"error\": \"no_title\", \"message\": \"A title is required to create a document\"}"
        }
        guard let content = args["content"] as? String else {
            return "{\"error\": \"no_content\", \"message\": \"Content is required\"}"
        }
        let folder = args["folder"] as? String ?? ""

        print("📝 [CREATE] title=\"\(title)\" folder=\"\(folder)\"")
        guard let file = vault.createFile(name: title, folderPath: folder, content: content) else {
            return "{\"error\": \"create_failed\", \"message\": \"Could not create '\(title)'. A file with that name may already exist.\"}"
        }

        service.addFoundFile(file, reason: "Created by assistant", snippet: String(content.prefix(100)), highlighted: true)
        return "{\"status\": \"created\", \"title\": \"\(file.title)\", \"path\": \"\(file.relativePath)\"}"
    }

    @MainActor
    private func executeMoveFile(vault: VaultManager, args: [String: Any]) -> String {
        guard let filename = args["filename"] as? String else {
            return "{\"error\": \"no_filename\"}"
        }
        guard let destinationFolder = args["destination_folder"] as? String else {
            return "{\"error\": \"no_destination\", \"message\": \"A destination folder is required\"}"
        }

        print("📦 [MOVE] \"\(filename)\" → \"\(destinationFolder)\"")
        guard let file = vault.resolveWikiLink(filename) else {
            return "{\"error\": \"not_found\", \"message\": \"Could not find a file called '\(filename)'\"}"
        }

        guard let moved = vault.moveFile(file, toFolder: destinationFolder) else {
            return "{\"error\": \"move_failed\", \"message\": \"Could not move '\(filename)' to '\(destinationFolder)'. A file with that name may already exist there.\"}"
        }

        service.addFoundFile(moved, reason: "Moved to \(destinationFolder.isEmpty ? "vault root" : destinationFolder)", snippet: moved.contentSnippet, highlighted: true)
        return "{\"status\": \"moved\", \"title\": \"\(moved.title)\", \"new_path\": \"\(moved.relativePath)\"}"
    }

    @MainActor
    private func executeExtractEntities(args: [String: Any]) -> String {
        var entities: [ExtractedEntity] = []
        var connections: [EntityConnection] = []

        if let entitiesArray = args["entities"] as? [[String: Any]] {
            for item in entitiesArray {
                if let name = item["name"] as? String,
                   let type = item["type"] as? String {
                    entities.append(ExtractedEntity(name: name, type: type))
                }
            }
        }

        if let connsArray = args["connections"] as? [[String: Any]] {
            for item in connsArray {
                if let from = item["from"] as? String,
                   let to = item["to"] as? String {
                    connections.append(EntityConnection(from: from, to: to))
                }
            }
        }

        if !entities.isEmpty {
            service.graphManager.ingestEntities(entities, connections: connections)
            print("🔗 [GRAPH] Ingested \(entities.count) entities, \(connections.count) connections")
        }

        return "{\"status\": \"ok\", \"entities_added\": \(entities.count)}"
    }

    private func extractSnippet(from file: VaultFile, query: String) -> String {
        let content = file.content ?? file.contentSnippet
        guard let range = content.range(of: query, options: .caseInsensitive) else {
            return String(content.prefix(100))
        }
        let start = content.index(range.lowerBound, offsetBy: -40, limitedBy: content.startIndex) ?? content.startIndex
        let end = content.index(range.upperBound, offsetBy: 60, limitedBy: content.endIndex) ?? content.endIndex
        var snippet = String(content[start..<end])
        if start != content.startIndex { snippet = "..." + snippet }
        if end != content.endIndex { snippet = snippet + "..." }
        return snippet
    }
}
