import Foundation
import WatchConnectivity

/// Phone-side bridge that manages a RealtimeVoiceProvider on behalf of the watch.
/// Watch sends mic audio → bridge feeds it to xAI WebSocket → bridge sends response audio back to watch.
@Observable
final class WatchVoiceBridge {
    private var grok: (any RealtimeVoiceProvider)?
    private let session = WCSession.default
    private(set) var isActive = false

    private var inputMode: VoiceInputMode = .interactive
    private var transcriptThrottleTask: Task<Void, Never>?
    private var pendingTranscriptUpdate = false

    /// Set by PhoneConnectivityManager to enable tool execution
    var vaultManager: VaultManager?
    var dataviewEngine: DataviewEngine?

    // Function call accumulation (mirroring VoicePageViewModel pattern)
    private let bufferLock = NSLock()
    private var functionCallBuffers: [String: String] = [:]
    private var functionCallNames: [String: String] = [:]

    /// Start a voice session on behalf of the watch
    func start(apiKey: String, config: WatchSessionConfig) {
        guard !isActive else { return }
        isActive = true

        let recordingMode = RecordingMode(rawValue: config.recordingMode) ?? .conversational
        let settings = VoiceSettings.shared
        let systemPrompt = recordingMode.systemPrompt(customRules: settings.creationCustomPrompt)
        inputMode = config.inputMode == "ptt" ? .ptt : .interactive

        let service = VoiceProviderFactory.makeRealtime(vendor: VoiceSettings.shared.realtimeVendor)
        service.voice = settings.selectedVoice

        // Don't capture local mic — audio comes from watch
        service.isCapturingAudio = false

        // Set tools so Voice AI can access the vault
        service.tools = AgentVoiceService.toolDefinitions

        // Intercept function call messages for tool execution
        service.onMessage = { [weak self] type, json in
            self?.handleMessage(type, json: json) ?? false
        }

        // Intercept audio output — send to watch instead of local speaker
        service.onAudioOutput = { [weak self] pcmData in
            self?.sendAudioToWatch(pcmData)
        }

        // Forward state changes immediately via callback
        service.onStateChange = { [weak self] state in
            self?.sendStateToWatch(WCVoiceState(from: state), state: state)
        }

        // Throttle transcript updates to avoid flooding WC (max ~5/sec)
        service.onTranscriptChange = { [weak self] transcript in
            self?.scheduleTranscriptUpdate(transcript)
        }

        // Build document context from recent vault files
        var docContent = ""
        if let vault = vaultManager, let dataview = dataviewEngine {
            let recentFiles = Array(vault.files.sorted { $0.modifiedDate > $1.modifiedDate }.prefix(20))
            let meta = dataview.fetchMetadata(for: recentFiles)
            let lines = recentFiles.map { file -> String in
                let fileMeta = meta[file.id]
                let title = file.title
                let snippet = file.contentSnippet.prefix(100)
                let dateStr = ISO8601DateFormatter().string(from: file.modifiedDate)
                var line = "- \(title) (\(dateStr)): \(snippet)"
                if let mood = fileMeta?.mood { line += " [mood: \(mood)]" }
                return line
            }
            docContent = "Recent notes:\n" + lines.joined(separator: "\n")
        }

        self.grok = service
        service.connect(apiKey: apiKey, documentContent: docContent, systemInstructions: systemPrompt)
    }

    /// Stop the voice session
    func stop() {
        transcriptThrottleTask?.cancel()
        grok?.onAudioOutput = nil
        grok?.onStateChange = nil
        grok?.onTranscriptChange = nil
        grok?.disconnect()
        grok = nil
        isActive = false
        sendStateToWatch(.disconnected)
    }

    /// Inject mic audio received from the watch
    func receivedAudioFromWatch(_ data: Data) {
        grok?.injectAudioData(data)
    }

    /// Handle PTT start from watch
    func handlePTTStart() {
        guard let grok else { return }
        grok.stopPlayback()
        grok.clearAudioBuffer()
    }

    /// Handle PTT stop from watch
    func handlePTTStop() {
        grok?.commitAudioBuffer()
    }

    /// Switch input mode
    func handleModeSwitch(inputMode: String) {
        guard let grok else { return }
        if inputMode == "interactive" {
            self.inputMode = .interactive
            grok.updateTurnDetection(enabled: true)
        } else {
            self.inputMode = .ptt
            grok.updateTurnDetection(enabled: false)
        }
    }

    // MARK: - Audio to Watch

    private func sendAudioToWatch(_ pcmData: Data) {
        guard session.isReachable else { return }
        var tagged = Data([WCVoiceMessageType.audioFromPhone])
        tagged.append(pcmData)
        session.sendMessageData(tagged, replyHandler: nil, errorHandler: nil)
    }

    // MARK: - State Forwarding

    private func sendStateToWatch(_ wcState: WCVoiceState, state: VoiceChatState? = nil) {
        guard session.isReachable else { return }
        var payload: [String: Any] = [
            "type": WCVoiceMessageType.voiceStateUpdate,
            "state": wcState.rawValue
        ]
        if case .error(let msg) = state {
            payload["errorMessage"] = msg
        }
        session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
    }

    // MARK: - Transcript Forwarding (throttled)

    private func scheduleTranscriptUpdate(_ transcript: TranscriptManager) {
        pendingTranscriptUpdate = true
        guard transcriptThrottleTask == nil else { return }
        // Send immediately, then throttle subsequent updates
        flushTranscript(transcript)
        transcriptThrottleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            self.transcriptThrottleTask = nil
            if self.pendingTranscriptUpdate, let grok = self.grok {
                self.flushTranscript(grok.transcript)
            }
        }
    }

    private func flushTranscript(_ transcript: TranscriptManager) {
        pendingTranscriptUpdate = false
        guard session.isReachable else { return }
        var turns: [[String: String]] = []
        for turn in transcript.turns {
            turns.append([
                "role": turn.role.rawValue,
                "text": turn.text
            ])
        }
        let payload: [String: Any] = [
            "type": WCVoiceMessageType.voiceTranscriptUpdate,
            "turns": turns,
            "currentAssistantText": transcript.currentAssistantText
        ]
        session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
    }

    // MARK: - Function Call Handling

    private func handleMessage(_ type: String, json: [String: Any]) -> Bool {
        switch type {
        case "response.function_call_arguments.delta":
            guard let callId = json["call_id"] as? String,
                  let delta = json["delta"] as? String else { return true }
            bufferLock.lock()
            functionCallBuffers[callId, default: ""] += delta
            bufferLock.unlock()
            return true

        case "response.function_call_arguments.done":
            guard let callId = json["call_id"] as? String,
                  let name = json["name"] as? String else { return true }
            bufferLock.lock()
            let args = functionCallBuffers[callId] ?? json["arguments"] as? String ?? "{}"
            functionCallNames[callId] = name
            bufferLock.unlock()

            Task {
                await executeToolCall(callId: callId, name: name, argumentsJSON: args)
            }
            return true

        case "response.output_item.done":
            if let item = json["item"] as? [String: Any],
               item["type"] as? String == "function_call" {
                return true
            }
            return false

        default:
            return false
        }
    }

    private func executeToolCall(callId: String, name: String, argumentsJSON: String) async {
        let args: [String: Any]
        if let data = argumentsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = parsed
        } else {
            args = [:]
        }

        let result = await executeToolOnMainActor(name: name, args: args)

        guard let grok else { return }

        let outputMessage: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": result
            ] as [String: Any]
        ]
        await grok.sendJSON(outputMessage)

        bufferLock.lock()
        functionCallBuffers.removeValue(forKey: callId)
        functionCallNames.removeValue(forKey: callId)
        let buffersEmpty = functionCallBuffers.isEmpty
        bufferLock.unlock()

        if buffersEmpty {
            await grok.sendJSON(["type": "response.create"])
        }
    }

    @MainActor
    private func executeToolOnMainActor(name: String, args: [String: Any]) -> String {
        guard let vault = vaultManager else {
            return "{\"error\": \"vault_unavailable\"}"
        }

        switch name {
        case "search_vault":
            return executeSearchVault(vault: vault, args: args)
        case "search_vault_by_date":
            return executeSearchByDate(vault: vault, args: args)
        case "search_vault_by_attribute":
            return executeSearchByAttribute(vault: vault, args: args)
        case "read_file_content":
            return executeReadFileContent(vault: vault, args: args)
        case "create_doc":
            return executeCreateDoc(vault: vault, args: args)
        case "move_file":
            return executeMoveFile(vault: vault, args: args)
        case "open_file":
            // On watch, we can't open files visually — just return info
            return executeReadFileContent(vault: vault, args: args)
        case "update_doc":
            return executeUpdateDoc(vault: vault, args: args)
        default:
            return "{\"error\": \"unknown_tool\"}"
        }
    }

    // MARK: - Tool Implementations

    @MainActor
    private func executeSearchVault(vault: VaultManager, args: [String: Any]) -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "{\"results\": [], \"message\": \"No query provided\"}"
        }

        var results: [VaultFile] = []
        if let dataview = dataviewEngine {
            let rankedPaths = dataview.searchNotes(query: query, limit: 10)
            let filesByPath = Dictionary(vault.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            results = rankedPaths.compactMap { filesByPath[$0] }
        }

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

        return buildResultJSON(results: results, query: query)
    }

    @MainActor
    private func executeSearchByDate(vault: VaultManager, args: [String: Any]) -> String {
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

        if let dataview = dataviewEngine {
            let paths = dataview.searchByDateRange(from: startDate, to: endDate)
            let filesByPath = Dictionary(vault.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let results = paths.compactMap { filesByPath[$0] }
            return buildResultJSON(results: results, query: "\(startStr) to \(endStr)")
        }

        // Fallback: filter by modifiedDate
        let results = Array(vault.files.filter { $0.modifiedDate >= startDate && $0.modifiedDate <= endDate }
            .sorted { $0.modifiedDate > $1.modifiedDate }.prefix(20))
        return buildResultJSON(results: results, query: "\(startStr) to \(endStr)")
    }

    @MainActor
    private func executeSearchByAttribute(vault: VaultManager, args: [String: Any]) -> String {
        guard let attribute = args["attribute"] as? String,
              let value = args["value"] as? String else {
            return "{\"results\": [], \"message\": \"Missing attribute or value\"}"
        }

        if let dataview = dataviewEngine {
            let paths = dataview.searchByAttribute(key: attribute, value: value)
            let filesByPath = Dictionary(vault.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let results = paths.compactMap { filesByPath[$0] }
            return buildResultJSON(results: results, query: "\(attribute): \(value)")
        }

        return "{\"results\": [], \"message\": \"Dataview engine not available\"}"
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
            return "{\"error\": \"no_title\"}"
        }
        guard let content = args["content"] as? String else {
            return "{\"error\": \"no_content\"}"
        }
        let folder = args["folder"] as? String ?? ""
        guard let file = vault.createFile(name: title, folderPath: folder, content: content) else {
            return "{\"error\": \"create_failed\"}"
        }
        return "{\"status\": \"created\", \"title\": \"\(file.title)\", \"path\": \"\(file.relativePath)\"}"
    }

    @MainActor
    private func executeMoveFile(vault: VaultManager, args: [String: Any]) -> String {
        guard let filename = args["filename"] as? String,
              let destinationFolder = args["destination_folder"] as? String else {
            return "{\"error\": \"missing_params\"}"
        }
        guard let file = vault.resolveWikiLink(filename) else {
            return "{\"error\": \"not_found\"}"
        }
        guard let moved = vault.moveFile(file, toFolder: destinationFolder) else {
            return "{\"error\": \"move_failed\"}"
        }
        return "{\"status\": \"moved\", \"title\": \"\(moved.title)\", \"new_path\": \"\(moved.relativePath)\"}"
    }

    @MainActor
    private func executeUpdateDoc(vault: VaultManager, args: [String: Any]) -> String {
        guard let filename = args["filename"] as? String else {
            return "{\"error\": \"no_filename\"}"
        }
        guard let file = vault.resolveWikiLink(filename) else {
            return "{\"error\": \"not_found\"}"
        }
        let fullContent = vault.loadContent(for: file)
        guard !fullContent.isEmpty else {
            return "{\"error\": \"icloud_pending\"}"
        }

        let (existingFrontmatter, body) = MarkdownParser.extractFrontmatter(fullContent)
        let newContent = args["content"] as? String

        var finalBody = body
        if let newContent {
            let mode = args["mode"] as? String ?? "replace"
            switch mode {
            case "append":
                finalBody = body + "\n\n" + newContent
            case "prepend":
                finalBody = newContent + "\n\n" + body
            default:
                finalBody = newContent
            }
        }

        let frontmatterBlock = existingFrontmatter.map { "---\n\($0)\n---\n\n" } ?? ""
        let updatedContent = frontmatterBlock + finalBody
        vault.updateFileContent(file, newContent: updatedContent)
        return "{\"status\": \"updated\", \"title\": \"\(file.title)\"}"
    }

    // MARK: - JSON Helpers

    private func buildResultJSON(results: [VaultFile], query: String) -> String {
        let items: [[String: String]] = results.map { file in
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd"
            return [
                "title": file.title,
                "path": file.relativePath,
                "date": dateFmt.string(from: file.modifiedDate),
                "snippet": String(file.contentSnippet.prefix(200))
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["results": items, "count": results.count, "query": query] as [String: Any]),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{\"results\": [], \"count\": 0}"
        }
        return jsonString
    }
}
