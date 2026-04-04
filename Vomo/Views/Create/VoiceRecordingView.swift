import SwiftUI
import Speech

// MARK: - Voice Recording View (Two-Phase)

/// Full-screen voice creation: Phase 1 = recording, Phase 2 = note editor with generation sheet
struct VoiceRecordingView: View {
    @Environment(VaultManager.self) var vault
    @Environment(TranscriptCache.self) var transcriptCache
    @Environment(\.dismiss) private var dismiss

    enum Phase { case recording, saving }

    // Phase
    @State private var phase: Phase = .recording

    // Recording state
    @State private var voiceService: (any RealtimeVoiceProvider)?
    @State private var voiceInputMode: VoiceInputMode = .interactive
    @State private var recordingMode: RecordingMode = .oneSided
    @State private var isPTTActive = false
    @State private var showApiKeyPrompt = false
    @State private var apiKeyInput = ""
    @State private var showSettings = false

    // Save state (populated on transition to .saving)
    @State private var cachedTranscriptID: UUID?
    @State private var cachedTranscript: CachedTranscript?
    @State private var noteTitle = ""
    @State private var noteContent = ""
    @State private var selectedFolder = ""
    @State private var isDiaryFolder = false
    @State private var showFolderPicker = false
    @State private var isSaving = false
    @State private var showSaveError = false

    // Generation sheet
    @State private var showGenerationSheet = false
    @State private var selectedSaveMode: SaveMode = .userThoughts
    @State private var density: Double = 0.5
    @State private var isGenerating = false
    @State private var hasGenerated = false
    @State private var sheetDetent: PresentationDetent = .medium
    @State private var transcriptFilePath: String = ""
    @State private var contentBlocks: [ContentBlock] = []

    @FocusState private var titleFocused: Bool
    @FocusState private var contentFocused: Bool

    var body: some View {
        Group {
            switch phase {
            case .recording:
                recordingPhaseView
            case .saving:
                savingPhaseView
            }
        }
        .background(Color(.systemBackground))
        .alert("Grok API Key", isPresented: $showApiKeyPrompt) {
            SecureField("xai-...", text: $apiKeyInput)
            Button("Save") {
                if !apiKeyInput.isEmpty {
                    _ = APIKeychain.save(vendor: VoiceSettings.shared.realtimeVendor.rawValue, key: apiKeyInput)
                    startVoiceSession()
                }
            }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text("Enter your xAI API key for voice creation.")
        }
    }

    // MARK: - Recording Phase

    private var recordingPhaseView: some View {
        VStack(spacing: 0) {
            recordingNavBar
            Divider()
            transcriptArea
                .frame(maxHeight: .infinity)
            Divider()
            voiceControls
        }
        .onAppear {
            startVoiceSession()
        }
        .onDisappear {
            if phase == .recording {
                voiceService?.disconnect()
                voiceService = nil
            }
        }
        .sheet(isPresented: $showSettings) {
            VoiceCreationSettingsSheet()
        }
    }

    private var recordingNavBar: some View {
        HStack {
            Button {
                voiceService?.disconnect()
                voiceService = nil
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            if let service = voiceService {
                // Recording mode badge
                Button {
                    toggleRecordingMode()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: recordingMode.icon)
                            .font(.caption2)
                        Text(recordingMode.label)
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(recordingMode == .oneSided ? .blue : .green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (recordingMode == .oneSided ? Color.blue : Color.green).opacity(0.15),
                        in: Capsule()
                    )
                }

                // Voice mode badge
                Text(voiceInputMode == .interactive ? "LIVE" : "PTT")
                    .font(.caption2.bold())
                    .foregroundStyle(voiceInputMode == .interactive ? .green : .orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (voiceInputMode == .interactive ? Color.green : Color.orange).opacity(0.15),
                        in: Capsule()
                    )

                if service.state == .responding {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Color.obsidianPurple)
                }
            }

            Spacer()

            // Write button
            Button {
                handleWrite()
            } label: {
                Text("Write")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.obsidianPurple, in: Capsule())
            }
            .disabled(voiceService?.transcript.isEmpty ?? true)
            .opacity((voiceService?.transcript.isEmpty ?? true) ? 0.4 : 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let service = voiceService {
                        ForEach(service.transcript.turns) { turn in
                            turnBubble(turn)
                        }

                        if !service.transcript.currentAssistantText.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(Color.obsidianPurple)
                                    .frame(width: 20)
                                Text(service.transcript.currentAssistantText)
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                            }
                            .id("streaming")
                        }

                        Color.clear.frame(height: 1).id("bottom")
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Connecting...")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 100)
                    }
                }
                .padding()
            }
            .onChange(of: voiceService?.transcript.turns.count) {
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: voiceService?.transcript.currentAssistantText) {
                withAnimation {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
        }
    }

    private func turnBubble(_ turn: TranscriptTurn) -> some View {
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
    }

    private var voiceControls: some View {
        VStack(spacing: 12) {
            HStack {
                // Settings
                Button { showSettings = true } label: {
                    ZStack {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: 44, height: 44)
                        Image(systemName: "gearshape")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Main mic button
                VoiceMicButton(
                    state: voiceService?.state ?? .disconnected,
                    inputMode: voiceInputMode,
                    isPTTActive: isPTTActive,
                    size: 64,
                    onTap: nil,
                    onPTTStart: {
                        guard let service = voiceService else { return }
                        isPTTActive = true
                        service.clearAudioBuffer()
                        service.isCapturingAudio = true
                    },
                    onPTTEnd: {
                        guard let service = voiceService else { return }
                        isPTTActive = false
                        service.isCapturingAudio = false
                        service.commitAudioBuffer()
                    }
                )

                Spacer()

                // Mode toggle (PTT/Live)
                Button {
                    if voiceInputMode == .interactive {
                        switchToPTT()
                    } else {
                        switchToInteractive()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: 44, height: 44)
                        VStack(spacing: 1) {
                            Image(systemName: voiceInputMode == .interactive ? "hand.tap.fill" : "waveform")
                                .font(.caption)
                            Text(voiceInputMode == .interactive ? "PTT" : "Live")
                                .font(.system(size: 8))
                        }
                        .foregroundStyle(voiceInputMode == .interactive ? .orange : .green)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 8)

            // Status text
            if let service = voiceService {
                Text(statusText(service.state))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
            }
        }
        .background(.ultraThinMaterial)
    }

    private func statusText(_ state: VoiceChatState) -> String {
        switch state {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return voiceInputMode == .interactive ? "Listening — speak your thoughts" : "Hold to talk"
        case .listening: return "Hearing you..."
        case .responding: return "Thinking..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    // MARK: - Voice Session

    private func startVoiceSession() {
        guard let apiKey = APIKeychain.load(vendor: VoiceSettings.shared.realtimeVendor.rawValue) else {
            showApiKeyPrompt = true
            return
        }

        let service = VoiceProviderFactory.makeRealtime(vendor: VoiceSettings.shared.realtimeVendor)
        service.voice = VoiceSettings.shared.selectedVoice

        let customRules = VoiceSettings.shared.creationCustomPrompt
        let systemPrompt = recordingMode.systemPrompt(customRules: customRules, vaultURL: vault.vaultURL)

        service.isCapturingAudio = true
        service.connect(apiKey: apiKey, documentContent: "", systemInstructions: systemPrompt)

        voiceService = service
        voiceInputMode = .interactive
    }

    private func toggleRecordingMode() {
        recordingMode = recordingMode == .oneSided ? .conversational : .oneSided
        // Reconnect with new system prompt
        guard let apiKey = APIKeychain.load(vendor: VoiceSettings.shared.realtimeVendor.rawValue) else { return }
        voiceService?.disconnect()

        let service = VoiceProviderFactory.makeRealtime(vendor: VoiceSettings.shared.realtimeVendor)
        service.voice = VoiceSettings.shared.selectedVoice

        let customRules = VoiceSettings.shared.creationCustomPrompt
        let systemPrompt = recordingMode.systemPrompt(customRules: customRules, vaultURL: vault.vaultURL)

        service.isCapturingAudio = voiceInputMode == .interactive
        service.connect(apiKey: apiKey, documentContent: "", systemInstructions: systemPrompt)

        voiceService = service
    }

    private func switchToInteractive() {
        voiceInputMode = .interactive
        isPTTActive = false
        voiceService?.isCapturingAudio = true
        voiceService?.updateTurnDetection(enabled: true)
    }

    private func switchToPTT() {
        voiceInputMode = .ptt
        isPTTActive = false
        voiceService?.isCapturingAudio = false
        voiceService?.updateTurnDetection(enabled: false)
    }

    // MARK: - Write Transition

    private func handleWrite() {
        guard let service = voiceService, !service.transcript.isEmpty else { return }

        // Save raw transcript to vault at Assets/Transcriptions/ as .md with frontmatter
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HH-mm"
        let transcriptFilename = fmt.string(from: Date()) + ".md"
        let transcriptText = service.transcript.formattedTranscript
        let transcriptMd = """
        ---
        type: voice
        saved: false
        title: ""
        date: \(ISO8601DateFormatter().string(from: Date()))
        mode: \(recordingMode.rawValue)
        ---

        \(transcriptText)
        """
        let transcriptionFolder = SettingsManager.shared.transcriptionFolder
        if SettingsManager.shared.saveTranscriptions {
            _ = vault.createFile(name: transcriptFilename, folderPath: transcriptionFolder, content: transcriptMd)
        }
        transcriptFilePath = "\(transcriptionFolder)/\(transcriptFilename)"

        // Cache the transcript
        let id = transcriptCache.save(service.transcript, mode: recordingMode)
        cachedTranscriptID = id
        cachedTranscript = transcriptCache.load(id)
        selectedSaveMode = SaveMode.defaultMode(for: recordingMode)

        // Disconnect voice
        service.disconnect()
        voiceService = nil

        // Resolve folder
        resolveDefaultFolder()

        // Switch phase
        withAnimation(.easeInOut(duration: 0.3)) {
            phase = .saving
        }

        // Open generation sheet after a brief delay for the transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            showGenerationSheet = true
        }
    }

    // MARK: - Saving Phase

    private var savingPhaseView: some View {
        VStack(spacing: 0) {
            // Nav bar
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    showFolderPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.caption)
                        Text(selectedFolder.isEmpty ? "Vault Root" : selectedFolder)
                            .font(.subheadline)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(Color.obsidianPurple)
                }

                Spacer()

                Button {
                    saveNote()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.obsidianPurple, in: Capsule())
                    }
                }
                .disabled(noteContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            // Title
            TextField("Title", text: $noteTitle)
                .font(.title2.bold())
                .focused($titleFocused)
                .padding(.horizontal)
                .padding(.top, 8)

            Divider()
                .padding(.top, 8)

            // Content editor
            if noteContent.isEmpty && !hasGenerated {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Choose a save mode and tap Generate")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                    Button("Open Options") {
                        sheetDetent = .medium
                        showGenerationSheet = true
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.obsidianPurple)
                    Spacer()
                }
            } else if isGenerating {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Generating note...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if !contentBlocks.isEmpty {
                ContentBlockListView(blocks: $contentBlocks)
            } else {
                TextEditor(text: $noteContent)
                    .font(.body)
                    .focused($contentFocused)
                    .padding(.horizontal, 8)
                    .scrollContentBackground(.hidden)
            }
        }
        .alert("Save Failed", isPresented: $showSaveError) {
            Button("OK") { }
        } message: {
            Text("Could not save the note. The file may already exist.")
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerSheet(vault: vault, selectedFolder: $selectedFolder, isDiaryFolder: $isDiaryFolder, showPicker: $showFolderPicker)
        }
        .sheet(isPresented: $showGenerationSheet) {
            generationSheetContent
                .presentationDetents([.height(60), .medium], selection: $sheetDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
    }

    // MARK: - Generation Sheet

    private var generationSheetContent: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 4)

            if hasGenerated && !isGenerating {
                // Peek state content
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Generated")
                        .font(.subheadline.bold())
                    Text("· Pull up to change style")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 12)
                .padding(.horizontal)
            }

            // Save mode picker
            VStack(spacing: 8) {
                ForEach(SaveMode.allCases) { mode in
                    Button {
                        selectedSaveMode = mode
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: mode.icon)
                                .font(.body)
                                .frame(width: 24)
                                .foregroundStyle(selectedSaveMode == mode ? Color.obsidianPurple : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.rawValue)
                                    .font(.subheadline.bold())
                                Text(mode.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedSaveMode == mode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.obsidianPurple)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            selectedSaveMode == mode
                                ? Color.obsidianPurple.opacity(0.08)
                                : Color(.systemGray6),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal)

            // Density slider
            if selectedSaveMode != .rawTranscript {
                VStack(spacing: 4) {
                    HStack {
                        Text("Density")
                            .font(.subheadline.bold())
                        Spacer()
                        Text("\(Int(density * 100))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $density, in: 0.2...1.0, step: 0.1)
                        .tint(Color.obsidianPurple)
                    HStack {
                        Text("Key points")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("Keep everything")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal)
            }

            // Generate button
            Button {
                generateNote()
            } label: {
                Group {
                    if isGenerating {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text("Generating...")
                        }
                    } else {
                        Text(hasGenerated ? "Regenerate" : "Generate")
                    }
                }
                .font(.body.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    isGenerating ? Color.gray : Color.obsidianPurple,
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
            .disabled(isGenerating)
            .padding(.horizontal)

            Spacer()
        }
    }

    // MARK: - Generation

    private func generateNote() {
        guard let transcript = cachedTranscript else { return }

        isGenerating = true

        Task {
            do {
                let apiKey = APIKeychain.load(vendor: VoiceSettings.shared.realtimeVendor.rawValue) ?? ""
                let result: String

                if selectedSaveMode == .rawTranscript {
                    result = transcript.formattedTranscript
                } else {
                    result = try await VoiceSummarizer.summarize(
                        transcript: transcript.formattedTranscript,
                        saveMode: selectedSaveMode,
                        density: density,
                        apiKey: apiKey,
                        vaultURL: vault.vaultURL
                    )
                }

                await MainActor.run {
                    parseGeneratedContent(result)
                    isGenerating = false
                    hasGenerated = true
                    sheetDetent = .height(60)
                }
            } catch {
                await MainActor.run {
                    // Fallback to raw transcript on error
                    parseGeneratedContent(transcript.formattedTranscript)
                    isGenerating = false
                    hasGenerated = true
                    sheetDetent = .height(60)
                }
            }
        }
    }

    /// Extract title from H1 heading, parse rest into toggleable blocks
    private func parseGeneratedContent(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
        var bodyStart = 0

        // Extract H1 title
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("## ") {
                noteTitle = trimmed.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                bodyStart = index + 1
                break
            }
        }

        if noteTitle.isEmpty {
            if let firstLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                noteTitle = String(firstLine.prefix(60))
            } else {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd HH:mm"
                noteTitle = "Voice Note \(fmt.string(from: Date()))"
            }
        }

        let body = lines[bodyStart...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        noteContent = body

        // Parse into blocks for structured editing (skip for raw transcript)
        if selectedSaveMode != .rawTranscript {
            let parsed = ContentBlockParser.parse(body)
            contentBlocks = parsed.count >= 2 ? parsed : []
        } else {
            contentBlocks = []
        }
    }

    // MARK: - Save

    private func saveNote() {
        // Assemble content from blocks if using block editor, otherwise use noteContent
        let content: String
        if !contentBlocks.isEmpty {
            content = ContentBlockParser.assemble(contentBlocks)
        } else {
            content = noteContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !content.isEmpty else { return }
        isSaving = true

        let filename: String
        if isDiaryFolder {
            filename = vault.todayDiaryFilename()
        } else {
            let safe = noteTitle
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            filename = (safe.isEmpty ? "Untitled" : String(safe.prefix(60))) + ".md"
        }

        let notePath = selectedFolder.isEmpty ? filename : "\(selectedFolder)/\(filename)"

        if vault.createFile(name: filename, folderPath: selectedFolder, content: content) != nil {
            SettingsManager.shared.creationDefaultFolder = selectedFolder
            // Mark transcript as saved
            if let id = cachedTranscriptID {
                transcriptCache.markSaved(id, notePath: notePath)
            }
            // Update transcript file frontmatter with saved status and title
            updateTranscriptFrontmatter(saved: true, title: noteTitle)
            dismiss()
        } else {
            isSaving = false
            showSaveError = true
        }
    }

    private func updateTranscriptFrontmatter(saved: Bool, title: String) {
        guard !transcriptFilePath.isEmpty, let vaultURL = vault.vaultURL else { return }
        let fileURL = vaultURL.appendingPathComponent(transcriptFilePath)

        let needsAccess = !vault.isLocalPath
        if needsAccess { guard fileURL.startAccessingSecurityScopedResource() else { return } }
        defer { if needsAccess { fileURL.stopAccessingSecurityScopedResource() } }

        guard var content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        content = content.replacingOccurrences(of: "saved: false", with: "saved: \(saved)")
        let safeTitle = title.replacingOccurrences(of: "\"", with: "'")
        content = content.replacingOccurrences(of: "title: \"\"", with: "title: \"\(safeTitle)\"")

        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func resolveDefaultFolder() {
        let preferred = SettingsManager.shared.creationDefaultFolder
        if !preferred.isEmpty {
            selectedFolder = preferred
            isDiaryFolder = isDiaryLike(preferred)
            return
        }
        if let diary = vault.detectDiaryFolder() {
            selectedFolder = diary
            isDiaryFolder = true
            return
        }
        selectedFolder = ""
        isDiaryFolder = false
    }
}

// MARK: - Content Block Model & Parser

enum BlockKind: Codable, Equatable {
    case heading(level: Int)
    case paragraph
    case bullet
}

struct ContentBlock: Identifiable {
    let id = UUID()
    var kind: BlockKind
    var text: String
    var included: Bool
    var depth: Int  // 0 = top-level, 1 = under heading
}

struct ContentBlockParser {
    static func parse(_ markdown: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var paragraphLines: [String] = []
        var underHeading = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let text = paragraphLines.joined(separator: " ")
            blocks.append(ContentBlock(kind: .paragraph, text: text, included: true, depth: underHeading ? 1 : 0))
            paragraphLines = []
        }

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty line flushes paragraph
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            // Heading (## or ###, skip #)
            if trimmed.hasPrefix("##") {
                flushParagraph()
                var level = 0
                for ch in trimmed { if ch == "#" { level += 1 } else { break } }
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(ContentBlock(kind: .heading(level: level), text: text, included: true, depth: 0))
                underHeading = true
                continue
            }

            // Bullet (- or * or 1.)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                let text = String(trimmed.dropFirst(2))
                blocks.append(ContentBlock(kind: .bullet, text: text, included: true, depth: underHeading ? 1 : 0))
                continue
            }
            if let dotIdx = trimmed.firstIndex(of: "."),
               dotIdx > trimmed.startIndex,
               trimmed[trimmed.startIndex..<dotIdx].allSatisfy(\.isNumber),
               trimmed.index(after: dotIdx) < trimmed.endIndex,
               trimmed[trimmed.index(after: dotIdx)] == " " {
                flushParagraph()
                let text = String(trimmed[trimmed.index(after: trimmed.index(after: dotIdx))...])
                blocks.append(ContentBlock(kind: .bullet, text: text, included: true, depth: underHeading ? 1 : 0))
                continue
            }

            // Regular text
            paragraphLines.append(trimmed)
        }

        flushParagraph()
        return blocks
    }

    /// Assemble markdown from included blocks only
    static func assemble(_ blocks: [ContentBlock]) -> String {
        var parts: [String] = []
        for block in blocks where block.included {
            switch block.kind {
            case .heading(let level):
                parts.append(String(repeating: "#", count: level) + " " + block.text)
            case .paragraph:
                parts.append(block.text)
            case .bullet:
                parts.append("- " + block.text)
            }
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Content Block List View

struct ContentBlockListView: View {
    @Binding var blocks: [ContentBlock]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    ContentBlockRow(
                        block: $blocks[index],
                        onToggle: { toggleBlock(at: index) }
                    )
                }
            }
            .padding()
        }
    }

    private func toggleBlock(at index: Int) {
        let block = blocks[index]
        let newState = !block.included
        blocks[index].included = newState

        // Heading toggle cascades to children
        if case .heading = block.kind {
            for i in (index + 1)..<blocks.count {
                if case .heading = blocks[i].kind { break }
                blocks[i].included = newState
            }
        } else {
            // If all children under a heading are unchecked, uncheck heading too
            var headingIndex: Int?
            for i in stride(from: index - 1, through: 0, by: -1) {
                if case .heading = blocks[i].kind {
                    headingIndex = i
                    break
                }
            }
            if let hi = headingIndex {
                var anyIncluded = false
                for i in (hi + 1)..<blocks.count {
                    if case .heading = blocks[i].kind { break }
                    if blocks[i].included { anyIncluded = true; break }
                }
                blocks[hi].included = anyIncluded
            }
        }
    }
}

struct ContentBlockRow: View {
    @Binding var block: ContentBlock
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Indent
            if block.depth > 0 {
                Spacer().frame(width: CGFloat(block.depth) * 16)
            }

            // Toggle checkbox
            Button(action: onToggle) {
                Image(systemName: block.included ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(block.included ? Color.obsidianPurple : Color.gray.opacity(0.4))
                    .font(.body)
            }
            .buttonStyle(.plain)

            // Content
            Group {
                switch block.kind {
                case .heading:
                    TextField("Section", text: $block.text)
                        .font(.headline)
                case .bullet:
                    HStack(alignment: .top, spacing: 4) {
                        Text("•")
                            .foregroundStyle(.secondary)
                            .font(.body)
                        TextField("", text: $block.text, axis: .vertical)
                            .font(.body)
                            .lineLimit(1...10)
                    }
                case .paragraph:
                    TextField("", text: $block.text, axis: .vertical)
                        .font(.body)
                        .lineLimit(1...10)
                }
            }
            .opacity(block.included ? 1 : 0.35)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Voice Creation Settings

struct VoiceCreationSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var customPrompt: String = VoiceSettings.shared.creationCustomPrompt

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $customPrompt)
                        .font(.body)
                        .frame(minHeight: 120)
                } header: {
                    Text("Custom Instructions")
                } footer: {
                    Text("Tell the AI how to guide you. For example: \"Focus on technical details\" or \"Ask about my feelings and motivations\". These are appended to the default prompt.")
                }

                Section {
                    Button("Reset to Default") {
                        customPrompt = ""
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Voice Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        VoiceSettings.shared.creationCustomPrompt = customPrompt
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
