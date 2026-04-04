import SwiftUI

/// Full-screen unified voice experience.
/// Dark themed. Context-aware. All agent tools always available.
struct VoicePage: View {
    @Environment(VaultManager.self) var vault
    @Environment(DataviewEngine.self) var dataview
    @Environment(TranscriptCache.self) var transcriptCache
    @Environment(\.dismiss) private var dismiss

    /// Shared voice view model — lives in ContentView so voice persists across dismissals
    @Bindable var viewModel: VoicePageViewModel
    /// When true, VoicePage is embedded as a tab (no dismiss/back button)
    var isTabMode = false
    /// Optional note context (if opened from a note)
    var contextFile: VaultFile?
    /// Called when user taps a found file to open it after dismissing voice mode
    var onOpenFile: ((VaultFile) -> Void)?
    @State private var showApiKeyPrompt = false
    @State private var showQuickTranscription = false
    @State private var textInput = ""
    @State private var showSaveSheet = false
    @State private var hasEndedSession = false
    @State private var metadataCache: [String: FileMetadata] = [:]
    @FocusState private var isTextInputFocused: Bool

    // Split view state — 3 snap modes
    enum SplitMode: CGFloat, CaseIterable {
        case notes = 0.7   // Notes maximized, voice minimized
        case half  = 0.4   // 40/60 split (voice-centric default)
        case voice = 0.0   // Voice maximized, notes hidden
    }
    @State private var splitMode: SplitMode = .voice
    @State private var dragOffset: CGFloat = 0
    @State private var notesAutoScroll = true
    @State private var chatAutoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            topBar

            Divider().opacity(0.3)

            // Context banner
            if let file = contextFile, !hasEndedSession {
                contextBanner(file)
            }

            // Main content area
            if isTabMode && viewModel.state == .disconnected && !hasEndedSession {
                voiceLanding
            } else if hasEndedSession {
                sessionEndedView
            } else {
                mainContent

                Divider().opacity(0.3)

                // Text input bar
                if viewModel.state != .disconnected {
                    textInputBar
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }

                // Bottom controls
                controlsBar
            }
        }
        .background(Color(.systemBackground))
        .voiceAPIKeyPrompt(isPresented: $showApiKeyPrompt) {
            startSession()
        }
        .onAppear {
            viewModel.contextFile = contextFile
            if viewModel.state == .disconnected {
                // In tab mode, show landing screen with connect buttons
                // In sheet mode, auto-connect immediately
                if !isTabMode {
                    startSession()
                }
            } else {
                // Re-wire tool execution callback when returning to VoicePage
                viewModel.onToolCall = { [vault, dataview] name, args in
                    await self.executeToolCall(vault: vault, dataview: dataview, name: name, args: args)
                }
            }
        }
        .fullScreenCover(isPresented: $showQuickTranscription) {
            QuickTranscriptionView()
                .environment(vault)
        }
        .sheet(isPresented: $showSaveSheet) {
            saveSheet
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            if isTabMode {
                Color.clear.frame(width: 44, height: 44)
            } else {
                Button {
                    viewModel.disconnect()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
            }

            Spacer()

            Text("Voice")
                .font(.headline)

            Spacer()

            if hasEndedSession {
                Button(isTabMode ? "New" : "Done") {
                    if isTabMode {
                        resetSession()
                    } else {
                        dismiss()
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.obsidianPurple)
                .frame(width: 44, height: 44)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Voice Landing (Disconnected)

    private var voiceLanding: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.obsidianPurple.opacity(0.3))

            Text("Start a voice session")
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 24) {
                // PTT button
                Button {
                    viewModel.session.switchToPTT()
                    startSession()
                } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.15))
                                .frame(width: 72, height: 72)
                            Image(systemName: "hand.tap.fill")
                                .font(.title2)
                                .foregroundStyle(.orange)
                        }
                        Text("Push to Talk")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                    }
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in
                            let generator = UIImpactFeedbackGenerator(style: .heavy)
                            generator.impactOccurred()
                            showQuickTranscription = true
                        }
                )

                // Interactive button
                Button {
                    viewModel.session.switchToInteractive()
                    startSession()
                } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(0.15))
                                .frame(width: 72, height: 72)
                            Image(systemName: "waveform")
                                .font(.title2)
                                .foregroundStyle(.green)
                        }
                        Text("Interactive")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                    }
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in
                            let generator = UIImpactFeedbackGenerator(style: .heavy)
                            generator.impactOccurred()
                            showQuickTranscription = true
                        }
                )
            }

            Text("Long press for transcription")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
    }

    // MARK: - Context Banner

    private func contextBanner(_ file: VaultFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.fill")
                .font(.caption)
                .foregroundStyle(Color.obsidianPurple)
            Text(file.title)
                .font(.caption.bold())
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.obsidianPurple.opacity(0.08))
    }

    // MARK: - Main Content (Split View)

    private var mainContent: some View {
        GeometryReader { geometry in
            let totalHeight = geometry.size.height
            let handleHeight: CGFloat = 32
            let minPaneHeight: CGFloat = 0
            let notesRatio = max(0, min(1, splitMode.rawValue + dragOffset / totalHeight))
            let notesH = max(minPaneHeight, (totalHeight - handleHeight) * notesRatio)

            VStack(spacing: 0) {
                // Notes pane — collapses in voice mode
                if splitMode != .voice || dragOffset != 0 {
                    notesPane
                        .frame(height: notesH)
                        .clipped()
                }

                // Drag handle
                splitHandle(totalHeight: totalHeight)
                    .frame(height: handleHeight)

                // Conversation pane
                conversationPane
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Notes Pane (top — search results, found files)

    private var notesPane: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        Color.clear.frame(height: 0).id("notes-top")

                        // Tool activity
                        if viewModel.isToolExecuting, let activity = viewModel.currentToolActivity {
                            HStack(alignment: .top, spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 20)
                                Text(activity)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .italic()
                            }
                            .padding(.horizontal)
                        }

                        // Found files (newest first)
                        ForEach(viewModel.foundFiles.reversed()) { found in
                            foundFileCard(found)
                                .id("note-\(found.id)")
                        }

                        if viewModel.foundFiles.isEmpty && !viewModel.isToolExecuting {
                            VStack(spacing: 8) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.title2)
                                    .foregroundStyle(.tertiary)
                                Text("Notes and search results appear here")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in notesAutoScroll = false }
                )
                .onChange(of: viewModel.foundFiles.count) {
                    if notesAutoScroll {
                        withAnimation {
                            proxy.scrollTo("notes-top", anchor: .top)
                        }
                    }
                    // Auto-expand to show notes when results arrive
                    if splitMode == .voice && !viewModel.foundFiles.isEmpty {
                        withAnimation(.spring(duration: 0.35)) {
                            splitMode = .half
                        }
                    }
                }

                if !notesAutoScroll && !viewModel.foundFiles.isEmpty {
                    Button {
                        notesAutoScroll = true
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("notes-top", anchor: .top)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Latest")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.obsidianPurple, in: Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 8, y: -4)
                    }
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(duration: 0.3), value: notesAutoScroll)
                }
            }
        }
    }

    // MARK: - Split Handle

    private func splitHandle(totalHeight: CGFloat) -> some View {
        VStack(spacing: 6) {
            Capsule()
                .fill(Color(.tertiaryLabel))
                .frame(width: 36, height: 4)

            // Mode label
            HStack(spacing: 4) {
                let label: String = {
                    let effective = splitMode.rawValue + dragOffset / totalHeight
                    if effective > 0.55 { return "Notes" }
                    if effective > 0.15 { return "Split" }
                    return "Voice"
                }()
                Image(systemName: splitMode == .voice ? "chevron.up" : splitMode == .notes ? "chevron.down" : "minus")
                    .font(.system(size: 8, weight: .bold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            // Cycle: voice → half → notes → voice
            withAnimation(.spring(duration: 0.35)) {
                switch splitMode {
                case .voice: splitMode = .half
                case .half:  splitMode = .notes
                case .notes: splitMode = .voice
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    let projected = value.predictedEndTranslation.height / totalHeight
                    let currentRatio = splitMode.rawValue + projected
                    // Snap to nearest mode
                    let target = SplitMode.allCases.min(by: {
                        abs($0.rawValue - currentRatio) < abs($1.rawValue - currentRatio)
                    }) ?? .half
                    withAnimation(.spring(duration: 0.3)) {
                        splitMode = target
                        dragOffset = 0
                    }
                }
        )
    }

    // MARK: - Conversation Pane (bottom — transcript)

    private var conversationPane: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.transcript.turns) { turn in
                            transcriptRow(turn)
                                .id(turn.id)
                        }

                        // Streaming text
                        if !viewModel.transcript.currentAssistantText.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(Color.obsidianPurple)
                                    .frame(width: 20)
                                Text(viewModel.transcript.currentAssistantText)
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal)
                            .id("streaming")
                        }

                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(.vertical)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in chatAutoScroll = false }
                )
                .onChange(of: viewModel.transcript.turns.count) {
                    if chatAutoScroll {
                        withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                    }
                }
                .onChange(of: viewModel.transcript.currentAssistantText) {
                    if chatAutoScroll {
                        withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
                    }
                }

                if !chatAutoScroll && !viewModel.transcript.isEmpty {
                    Button {
                        chatAutoScroll = true
                        withAnimation(.easeOut(duration: 0.3)) {
                            if !viewModel.transcript.currentAssistantText.isEmpty {
                                proxy.scrollTo("streaming", anchor: .bottom)
                            } else {
                                proxy.scrollTo("chat-bottom", anchor: .bottom)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Latest")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.obsidianPurple, in: Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    }
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(duration: 0.3), value: chatAutoScroll)
                }
            }
        }
    }

    private func transcriptRow(_ turn: TranscriptTurn) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: turn.role == .user ? "person.fill" : "sparkles")
                .font(.caption)
                .foregroundStyle(turn.role == .user ? .primary : Color.obsidianPurple)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(turn.role == .user ? "You" : "Assistant")
                    .font(.caption2.bold())
                    .foregroundStyle(.tertiary)
                Text(turn.text)
                    .font(.callout)
            }
        }
        .padding(.horizontal)
    }

    private func foundFileCard(_ found: FoundFile) -> some View {
        Button {
            vault.markAsRecent(found.file)
            onOpenFile?(found.file)
            if !isTabMode { dismiss() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: found.isHighlighted ? "doc.text.fill" : "doc.text")
                    .font(.body)
                    .foregroundStyle(found.isHighlighted ? Color.obsidianPurple : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(found.file.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(found.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    // MARK: - Text Input

    private var textInputBar: some View {
        HStack(spacing: 8) {
            TextField("Type a message...", text: $textInput)
                .focused($isTextInputFocused)
                .font(.subheadline)
                .submitLabel(.send)
                .onSubmit { sendText() }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 10))

            if !textInput.isEmpty {
                Button {
                    sendText()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.obsidianPurple)
                }
            }
        }
    }

    private func sendText() {
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        viewModel.session.sendTextMessage(text)
        textInput = ""
    }

    // MARK: - Controls Bar

    private var controlsBar: some View {
        VStack(spacing: 4) {
        HStack {
            // Mode toggle
            Button {
                if viewModel.inputMode == .interactive {
                    viewModel.session.switchToPTT()
                } else {
                    viewModel.session.switchToInteractive()
                }
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: viewModel.inputMode == .interactive ? "hand.tap.fill" : "waveform")
                        .font(.caption)
                    Text(viewModel.inputMode == .interactive ? "PTT" : "Live")
                        .font(.system(size: 8))
                }
                .foregroundStyle(viewModel.inputMode == .interactive ? .orange : .green)
                .frame(width: 44, height: 44)
            }

            Spacer()

            // Main mic button
            VoiceMicButton(
                state: viewModel.state,
                inputMode: viewModel.inputMode,
                isPTTActive: viewModel.isPTTActive,
                size: 64,
                onTap: { handleMicTap() },
                onPTTStart: { viewModel.session.startPTT() },
                onPTTEnd: { viewModel.session.stopPTT() }
            )

            Spacer()

            // End session / Close
            Button {
                endSession()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 44, height: 44)
                    Image(systemName: "stop.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .disabled(viewModel.state == .disconnected)
            .opacity(viewModel.state == .disconnected ? 0.3 : 1)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)

        // Status
        VoiceStatusIndicator(
            state: viewModel.state,
            inputMode: viewModel.inputMode,
            toolActivity: viewModel.isToolExecuting ? viewModel.currentToolActivity : nil
        )
        .padding(.horizontal)
        .padding(.bottom, 8)
        }
    }

    // MARK: - Session Ended View

    private var sessionEndedView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Session ended")
                .font(.headline)

            if !viewModel.transcript.isEmpty {
                Text("\(viewModel.transcript.turnCount) turns")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    showSaveSheet = true
                } label: {
                    Text("Save to Note")
                        .font(.body.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.obsidianPurple, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 40)
            }

            Button(isTabMode ? "New Session" : "Dismiss") {
                if isTabMode {
                    resetSession()
                } else {
                    dismiss()
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Spacer()
        }
    }

    // MARK: - Save Sheet

    @ViewBuilder
    private var saveSheet: some View {
        if let file = contextFile {
            // Save back to existing note
            VoiceSummarizeSheet(
                file: file,
                transcript: viewModel.transcript,
                isPresented: $showSaveSheet
            )
        } else {
            // Create new note from transcript
            VoiceSaveNewNoteSheet(
                transcript: viewModel.transcript,
                transcriptCache: transcriptCache,
                isPresented: $showSaveSheet
            )
        }
    }

    // MARK: - Actions

    private func resetSession() {
        viewModel.disconnect()
        hasEndedSession = false
        showSaveSheet = false
        textInput = ""
        splitMode = .voice
        // In tab mode, return to landing screen; in sheet mode, reconnect
        if !isTabMode {
            startSession()
        }
    }

    private func startSession() {
        guard APIKeychain.hasKey(vendor: VoiceSettings.shared.realtimeVendor.rawValue) else {
            showApiKeyPrompt = true
            return
        }

        // Wire up tool execution
        viewModel.onToolCall = { [vault, dataview] name, args in
            await self.executeToolCall(vault: vault, dataview: dataview, name: name, args: args)
        }

        viewModel.connect(vault: vault)

        // Send context message if we have a note
        if contextFile != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                viewModel.sendContextMessage()
            }
        }
    }

    private func handleMicTap() {
        switch viewModel.state {
        case .disconnected, .error:
            startSession()
        case .connecting:
            break
        case .connected, .listening, .responding:
            // In interactive mode, tapping mic does nothing special
            break
        }
    }

    private func endSession() {
        viewModel.disconnect()
        withAnimation {
            hasEndedSession = true
        }
    }

    // MARK: - Tool Execution

    @MainActor
    private func executeToolCall(vault: VaultManager, dataview: DataviewEngine, name: String, args: [String: Any]) async -> String {
        switch name {
        case "search_vault":
            return executeSearchVault(vault: vault, dataview: dataview, args: args)
        case "search_vault_by_date":
            return executeSearchByDate(vault: vault, dataview: dataview, args: args)
        case "search_vault_by_attribute":
            return executeSearchByAttribute(vault: vault, dataview: dataview, args: args)
        case "open_file":
            return executeOpenFile(vault: vault, args: args)
        case "read_file_content":
            return executeReadFileContent(vault: vault, args: args)
        case "create_doc":
            return executeCreateDoc(vault: vault, args: args)
        case "move_file":
            return executeMoveFile(vault: vault, args: args)
        case "update_doc":
            return executeUpdateDoc(vault: vault, dataview: dataview, args: args)
        default:
            return "{\"error\": \"unknown_tool\"}"
        }
    }

    @MainActor
    private func executeSearchVault(vault: VaultManager, dataview: DataviewEngine, args: [String: Any]) -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "{\"results\": [], \"message\": \"No query provided\"}"
        }

        let rankedPaths = dataview.searchNotes(query: query, limit: 10)
        let filesByPath = Dictionary(vault.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var results = rankedPaths.compactMap { filesByPath[$0] }

        if results.isEmpty {
            let lowered = query.lowercased()
            results = Array(vault.files.filter { file in
                file.title.localizedCaseInsensitiveContains(lowered) ||
                file.contentSnippet.localizedCaseInsensitiveContains(lowered)
            }.sorted { $0.modifiedDate > $1.modifiedDate }.prefix(10))
        }

        if results.isEmpty {
            return "{\"results\": [], \"message\": \"No notes found matching '\(query)'\"}"
        }

        let meta = dataview.fetchMetadata(for: results)
        metadataCache.merge(meta) { _, new in new }

        for file in results {
            let snippet = extractSnippet(from: file, query: query.lowercased())
            viewModel.addFoundFile(file, reason: "Matched '\(query)'", snippet: snippet)
        }

        return buildResultJSON(results: results, meta: meta, query: query)
    }

    @MainActor
    private func executeSearchByDate(vault: VaultManager, dataview: DataviewEngine, args: [String: Any]) -> String {
        guard let startStr = args["start_date"] as? String,
              let endStr = args["end_date"] as? String else {
            return "{\"results\": [], \"message\": \"Missing dates\"}"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let startDate = fmt.date(from: startStr),
              let endDate = fmt.date(from: endStr) else {
            return "{\"results\": [], \"message\": \"Invalid date format\"}"
        }
        let paths = dataview.searchByDateRange(from: startDate, to: endDate)
        return buildFoundFilesResponse(vault: vault, dataview: dataview, paths: paths, reason: "Date: \(startStr) to \(endStr)")
    }

    @MainActor
    private func executeSearchByAttribute(vault: VaultManager, dataview: DataviewEngine, args: [String: Any]) -> String {
        guard let attribute = args["attribute"] as? String, !attribute.isEmpty else {
            return "{\"results\": [], \"message\": \"No attribute provided\"}"
        }
        guard let value = args["value"] as? String, !value.isEmpty else {
            return "{\"results\": [], \"message\": \"No value provided\"}"
        }
        let paths = dataview.searchByAttribute(key: attribute, value: value)
        return buildFoundFilesResponse(vault: vault, dataview: dataview, paths: paths, reason: "\(attribute): \(value)")
    }

    @MainActor
    private func executeOpenFile(vault: VaultManager, args: [String: Any]) -> String {
        guard let filename = args["filename"] as? String else {
            return "{\"error\": \"no_filename\"}"
        }
        guard let file = vault.resolveWikiLink(filename) else {
            return "{\"error\": \"not_found\", \"message\": \"Could not find '\(filename)'\"}"
        }
        viewModel.addFoundFile(file, reason: "Opened by assistant", snippet: file.contentSnippet, highlighted: true)
        vault.markAsRecent(file)
        return "{\"status\": \"opened\", \"title\": \"\(file.title)\"}"
    }

    @MainActor
    private func executeReadFileContent(vault: VaultManager, args: [String: Any]) -> String {
        guard let filename = args["filename"] as? String else {
            return "{\"error\": \"no_filename\"}"
        }
        guard let file = vault.resolveWikiLink(filename) else {
            return "{\"error\": \"not_found\"}"
        }
        let fullContent = vault.loadContent(for: file)
        if fullContent.isEmpty {
            return "{\"error\": \"icloud_pending\"}"
        }
        let (_, body) = MarkdownParser.extractFrontmatter(fullContent)
        let truncated = body.count > 4000 ? String(body.prefix(4000)) + "\n[...truncated]" : body
        viewModel.addFoundFile(file, reason: "Read by assistant", snippet: String(body.prefix(100)))

        guard let data = try? JSONSerialization.data(withJSONObject: [
            "title": file.title, "path": file.relativePath, "content": truncated
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

        guard let file = vault.createFile(name: title, folderPath: folder, content: content) else {
            return "{\"error\": \"create_failed\", \"message\": \"Could not create '\(title)'. A file with that name may already exist.\"}"
        }

        viewModel.addFoundFile(file, reason: "Created by assistant", snippet: String(content.prefix(100)), highlighted: true)
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

        guard let file = vault.resolveWikiLink(filename) else {
            return "{\"error\": \"not_found\", \"message\": \"Could not find a file called '\(filename)'\"}"
        }

        guard let moved = vault.moveFile(file, toFolder: destinationFolder) else {
            return "{\"error\": \"move_failed\", \"message\": \"Could not move '\(filename)' to '\(destinationFolder)'. A file with that name may already exist there.\"}"
        }

        viewModel.addFoundFile(moved, reason: "Moved to \(destinationFolder.isEmpty ? "vault root" : destinationFolder)", snippet: moved.contentSnippet, highlighted: true)
        return "{\"status\": \"moved\", \"title\": \"\(moved.title)\", \"new_path\": \"\(moved.relativePath)\"}"
    }

    @MainActor
    private func executeUpdateDoc(vault: VaultManager, dataview: DataviewEngine, args: [String: Any]) -> String {
        guard let filename = args["filename"] as? String else {
            return "{\"error\": \"no_filename\"}"
        }
        guard let file = vault.resolveWikiLink(filename) else {
            return "{\"error\": \"not_found\", \"message\": \"Could not find '\(filename)'\"}"
        }

        let fullContent = vault.loadContent(for: file)
        guard !fullContent.isEmpty else {
            return "{\"error\": \"icloud_pending\", \"message\": \"File not yet downloaded from iCloud\"}"
        }

        let (existingFrontmatter, body) = MarkdownParser.extractFrontmatter(fullContent)
        let newProperties = args["properties"] as? [String: Any]
        let newContent = args["content"] as? String
        let mode = args["mode"] as? String ?? "replace"

        // Nothing to update
        guard newProperties != nil || newContent != nil else {
            return "{\"error\": \"nothing_to_update\", \"message\": \"Provide properties and/or content to update\"}"
        }

        // Update frontmatter
        var frontmatterLines: [String] = existingFrontmatter?.components(separatedBy: "\n") ?? []

        if let props = newProperties {
            for (key, value) in props {
                let yamlValue = formatYAMLValue(key: key, value: value, dataview: dataview, filePath: file.id)
                let newLine = "\(key): \(yamlValue)"

                // Find existing line for this key and replace, or append
                if let idx = frontmatterLines.firstIndex(where: { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed.hasPrefix("\(key):") || trimmed.hasPrefix("\(key) :")
                }) {
                    // Check if this is a multi-line list (next lines start with "  - ")
                    var endIdx = idx + 1
                    while endIdx < frontmatterLines.count {
                        let nextLine = frontmatterLines[endIdx]
                        if nextLine.hasPrefix("  - ") || nextLine.hasPrefix("    ") {
                            endIdx += 1
                        } else {
                            break
                        }
                    }
                    // Replace the key line and any continuation lines
                    let replacement = yamlValue.contains("\n") ? newLine.components(separatedBy: "\n") : [newLine]
                    frontmatterLines.replaceSubrange(idx..<endIdx, with: replacement)
                } else {
                    // Append new property (handle multi-line)
                    if yamlValue.contains("\n") {
                        frontmatterLines.append(contentsOf: newLine.components(separatedBy: "\n"))
                    } else {
                        frontmatterLines.append(newLine)
                    }
                }
            }
        }

        // Reconstruct body
        var updatedBody: String
        switch mode {
        case "append":
            updatedBody = body + "\n" + (newContent ?? "")
        case "prepend":
            updatedBody = (newContent ?? "") + "\n" + body
        default: // replace
            updatedBody = newContent ?? body
        }

        // Reconstruct document
        let updatedFrontmatter = frontmatterLines.joined(separator: "\n")
        let updatedDocument: String
        if updatedFrontmatter.isEmpty {
            updatedDocument = updatedBody
        } else {
            updatedDocument = "---\n\(updatedFrontmatter)\n---\n\(updatedBody)"
        }

        vault.updateFileContent(file, newContent: updatedDocument)

        var changes: [String] = []
        if let props = newProperties { changes.append("\(props.count) properties") }
        if newContent != nil { changes.append("body (\(mode))") }
        viewModel.addFoundFile(file, reason: "Updated: \(changes.joined(separator: ", "))", snippet: String(updatedBody.prefix(100)), highlighted: true)

        return "{\"status\": \"updated\", \"title\": \"\(file.title)\", \"changes\": \"\(changes.joined(separator: ", "))\"}"
    }

    /// Format a value for YAML frontmatter, inferring type from vault context.
    private func formatYAMLValue(key: String, value: Any, dataview: DataviewEngine, filePath: String) -> String {
        // Handle null/removal
        if value is NSNull { return "" }

        // Handle arrays (tags, aliases, etc.)
        if let array = value as? [Any] {
            if array.isEmpty { return "[]" }
            let items = array.map { item -> String in
                let str = "\(item)"
                return "  - \(str)"
            }
            return "\n" + items.joined(separator: "\n")
        }

        // Handle booleans
        if let bool = value as? Bool { return bool ? "true" : "false" }

        // Handle numbers
        if let num = value as? NSNumber, !(value is Bool) {
            if num.doubleValue == num.doubleValue.rounded() && abs(num.doubleValue) < 1e15 {
                return "\(num.intValue)"
            }
            return "\(num.doubleValue)"
        }

        guard let str = value as? String else { return "\"\(value)\"" }

        // Check vault samples for this property to infer format
        let samples = dataview.propertySamples(key: key, excludingPath: filePath)

        // Date detection: if vault stores this key as dates, format as date
        let hasDateSamples = samples.contains { $0.date != nil }
        if hasDateSamples || looksLikeDate(str) {
            if let normalized = normalizeDate(str) { return normalized }
        }

        // Wikilink detection: if other notes use wikilinks for this key
        let hasWikilinkSamples = samples.contains { ($0.text ?? "").contains("[[") }
        if hasWikilinkSamples && !str.contains("[[") {
            return "\"[[\(str)]]\""
        }

        // If value already has wikilinks, preserve them
        if str.contains("[[") { return "\"\(str)\"" }

        // Number detection
        if let _ = Double(str), !str.contains("-") { return str }

        // Boolean detection
        if str.lowercased() == "true" || str.lowercased() == "false" { return str.lowercased() }

        // Default: string value, quote if it contains special YAML chars
        let needsQuoting = str.contains(":") || str.contains("#") || str.contains("\"") ||
            str.contains("'") || str.contains("\n") || str.contains("[") || str.contains("{") ||
            str.hasPrefix(" ") || str.hasSuffix(" ")
        return needsQuoting ? "\"\(str.replacingOccurrences(of: "\"", with: "\\\""))\"" : str
    }

    private func looksLikeDate(_ str: String) -> Bool {
        let datePattern = /^\d{4}-\d{2}-\d{2}/
        return str.contains(datePattern)
    }

    private func normalizeDate(_ str: String) -> String? {
        // Already in YYYY-MM-DD format
        let isoPattern = /^(\d{4}-\d{2}-\d{2})/
        if let match = str.firstMatch(of: isoPattern) {
            return String(match.1)
        }
        // Try common formats
        let formats = ["MM/dd/yyyy", "MMMM d, yyyy", "MMM d, yyyy", "d MMMM yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        let outFormatter = DateFormatter()
        outFormatter.dateFormat = "yyyy-MM-dd"
        for fmt in formats {
            formatter.dateFormat = fmt
            if let date = formatter.date(from: str) {
                return outFormatter.string(from: date)
            }
        }
        return nil
    }

    // MARK: - Helpers

    @MainActor
    private func buildFoundFilesResponse(vault: VaultManager, dataview: DataviewEngine, paths: [String], reason: String) -> String {
        let filesByPath = Dictionary(vault.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let results = paths.compactMap { filesByPath[$0] }
        if results.isEmpty {
            return "{\"results\": [], \"message\": \"No notes found\"}"
        }
        let meta = dataview.fetchMetadata(for: results)
        metadataCache.merge(meta) { _, new in new }
        for file in results {
            viewModel.addFoundFile(file, reason: reason, snippet: file.contentSnippet)
        }
        return buildResultJSON(results: results, meta: meta, query: nil)
    }

    private func buildResultJSON(results: [VaultFile], meta: [String: FileMetadata], query: String?) -> String {
        let resultDicts: [[String: Any]] = results.map { file in
            var dict: [String: Any] = [
                "title": file.title,
                "path": file.relativePath,
                "snippet": query != nil ? extractSnippet(from: file, query: query!.lowercased()) : String(file.contentSnippet.prefix(100))
            ]
            if let m = meta[file.id] {
                if let d = m.dateDisplay { dict["date"] = d }
                if let mood = m.mood { dict["mood"] = mood }
                if !m.tags.isEmpty { dict["tags"] = m.tags }
            }
            return dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["results": resultDicts, "count": results.count] as [String: Any]),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{\"results\": [], \"error\": \"serialization_error\"}"
        }
        return jsonString
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

// MARK: - Save New Note Sheet (for VoicePage without context)

struct VoiceSaveNewNoteSheet: View {
    let transcript: TranscriptManager
    let transcriptCache: TranscriptCache
    @Binding var isPresented: Bool
    @Environment(VaultManager.self) var vault
    @Environment(\.dismiss) private var dismiss

    @State private var selectedStyle: SummarizationStyle = .conversational
    @State private var isSummarizing = false
    @State private var summary: String?
    @State private var noteTitle = ""
    @State private var selectedFolder = ""
    @State private var isDiaryFolder = false
    @State private var showFolderPicker = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Summary Style") {
                    ForEach(SummarizationStyle.allCases) { style in
                        Button {
                            selectedStyle = style
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(style.rawValue)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(style.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedStyle == style {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.obsidianPurple)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let summary {
                    Section("Preview") {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Save Location") {
                        TextField("Note Title", text: $noteTitle)
                            .font(.subheadline)

                        Button {
                            showFolderPicker = true
                        } label: {
                            HStack {
                                Text("Folder")
                                Spacer()
                                Text(selectedFolder.isEmpty ? "Vault Root" : selectedFolder)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let error {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Save Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if summary != nil {
                        Button("Save") { saveNote() }
                            .disabled(isSummarizing)
                    } else {
                        Button("Summarize") { generateSummary() }
                            .disabled(isSummarizing || transcript.isEmpty)
                    }
                }
            }
            .overlay {
                if isSummarizing {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Processing...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerSheet(vault: vault, selectedFolder: $selectedFolder, isDiaryFolder: $isDiaryFolder, showPicker: $showFolderPicker)
        }
        .onAppear {
            selectedFolder = SettingsManager.shared.creationDefaultFolder
        }
    }

    private func generateSummary() {
        guard let apiKey = APIKeychain.load(vendor: VoiceSettings.shared.realtimeVendor.rawValue) else { return }
        isSummarizing = true
        error = nil

        Task {
            do {
                let result = try await VoiceSummarizer.summarize(
                    transcript: transcript.formattedTranscript,
                    style: selectedStyle,
                    apiKey: apiKey,
                    vaultURL: vault.vaultURL
                )
                await MainActor.run {
                    summary = result
                    // Extract title from first line
                    let lines = result.components(separatedBy: .newlines)
                    if let firstLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        noteTitle = firstLine
                            .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespaces)
                    }
                    isSummarizing = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isSummarizing = false
                }
            }
        }
    }

    private func saveNote() {
        guard let content = summary, !content.isEmpty else { return }
        isSummarizing = true

        let safeName = noteTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = (safeName.isEmpty ? "Voice Session" : String(safeName.prefix(60))) + ".md"

        if vault.createFile(name: filename, folderPath: selectedFolder, content: content) != nil {
            SettingsManager.shared.creationDefaultFolder = selectedFolder
            isSummarizing = false
            isPresented = false
        } else {
            error = "Could not save the note."
            isSummarizing = false
        }
    }
}
