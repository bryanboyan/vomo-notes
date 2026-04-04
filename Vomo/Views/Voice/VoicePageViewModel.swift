import Foundation
import UIKit

/// Manages voice session + agent tool execution for the unified VoicePage.
/// Merges VoiceRecordingView's session logic + AgentVoiceService's tool handling.
@Observable
final class VoicePageViewModel {
    let session = VoiceSession()
    private(set) var foundFiles: [FoundFile] = []
    private(set) var isToolExecuting = false
    private(set) var currentToolActivity: String?

    /// Note context (if opened from a note)
    var contextFile: VaultFile?

    /// Callback for tool execution — provided by the owning view
    var onToolCall: ((String, [String: Any]) async -> String)?

    /// Callback when agent opens a file
    var onOpenFile: ((VaultFile) -> Void)?

    // Accumulator for streaming function call arguments
    // Accessed from WebSocket background thread — synchronized via lock
    private let bufferLock = NSLock()
    private var functionCallBuffers: [String: String] = [:]
    private var functionCallNames: [String: String] = [:]

    var state: VoiceChatState { session.state }
    var transcript: TranscriptManager { session.transcript }
    var inputMode: VoiceInputMode { session.inputMode }
    var isPTTActive: Bool { session.isPTTActive }

    init() {
        session.onMessage = { [weak self] type, json in
            self?.handleMessage(type, json: json) ?? false
        }
    }

    // MARK: - Connect

    func connect(vault: VaultManager) {
        guard let apiKey = APIKeychain.load(vendor: VoiceSettings.shared.realtimeVendor.rawValue) else { return }

        let config = buildConfig(vault: vault)
        session.connect(apiKey: apiKey, config: config)
    }

    func disconnect() {
        session.disconnect()
        bufferLock.lock()
        functionCallBuffers.removeAll()
        functionCallNames.removeAll()
        bufferLock.unlock()
        currentToolActivity = nil
        isToolExecuting = false
    }

    private func buildConfig(vault: VaultManager) -> VoiceSessionConfig {
        let rules = VoiceSettings.shared.searchCustomRules.trimmingCharacters(in: .whitespacesAndNewlines)

        var systemPrompt: String
        if let override = VomoConfig.readPromptFile("agent.txt", vaultURL: vault.vaultURL) {
            let vars: [String: String] = [
                "file_count": "\(vault.files.count)",
                "today": Self.todayString,
                "custom_rules": rules
            ]
            systemPrompt = VomoConfig.applyVariables(VomoConfig.stripComments(override), vars: vars)
        } else {
            systemPrompt = """
            You are a voice assistant for the user's Obsidian vault. You can search, \
            browse, open, and read their notes. Keep responses concise for voice.

            CAPABILITIES:
            - Search for notes by topic, keyword, or content (search_vault)
            - Search by date range — "last week", "yesterday", "in March" (search_vault_by_date)
            - Search by metadata attribute — tag, mood, status, category, etc. (search_vault_by_attribute)
            - Open specific files for the user to view (open_file)
            - Read file contents to answer questions or discuss them (read_file_content)
            - Create new documents — "write a note about X", "create a doc" (create_doc)
            - Move files to different folders — "move this to Projects" (move_file)

            OBSIDIAN FORMAT:
            - This is an Obsidian vault. Notes are markdown files.
            - To reference another note, use wikilinks: [[Note Title]]
            - To reference with an alias: [[Note Title|display text]]
            - When creating docs with create_doc, use wikilinks to link related notes.
            - Tags use # prefix in frontmatter or inline: #tag

            BEHAVIOR:
            - Pick the right tool for the query type
            - For temporal queries, ALWAYS use search_vault_by_date
            - For attribute queries, use search_vault_by_attribute
            - Announce what you found briefly
            - Keep responses concise — this is voice, not text
            - Today's date is \(Self.todayString).

            The user's vault contains \(vault.files.count) notes.
            """

            // Append custom rules
            if !rules.isEmpty {
                systemPrompt += "\n\nUSER RULES:\n\(rules)"
            }
        }

        // Append vault-level voice instructions from .vomo/voice_instructions.txt
        if let voiceInstructions = VomoConfig.voiceInstructions(vaultURL: vault.vaultURL) {
            systemPrompt += "\n\nADDITIONAL INSTRUCTIONS:\n\(voiceInstructions)"
        }

        return VoiceSessionConfig(
            systemInstructions: systemPrompt,
            tools: AgentVoiceService.toolDefinitions
        )
    }

    /// Send context about the currently viewed note as an initial user message
    func sendContextMessage() {
        guard let file = contextFile else { return }
        let message = "I'm currently viewing: \(file.title) (\(file.relativePath))"
        session.sendTextMessage(message)
    }

    // MARK: - Found Files

    func addFoundFile(_ file: VaultFile, reason: String, snippet: String, highlighted: Bool = false) {
        guard !foundFiles.contains(where: { $0.file.id == file.id }) else {
            if highlighted, let idx = foundFiles.firstIndex(where: { $0.file.id == file.id }) {
                let existing = foundFiles[idx]
                foundFiles[idx] = FoundFile(file: existing.file, reason: existing.reason, snippet: existing.snippet, isHighlighted: true)
            }
            return
        }
        let found = FoundFile(file: file, reason: reason, snippet: snippet, isHighlighted: highlighted)
        foundFiles.insert(found, at: 0)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Message Interception

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

            Task { @MainActor in
                isToolExecuting = true
                currentToolActivity = toolActivityMessage(for: name)
            }

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

    private func toolActivityMessage(for name: String) -> String {
        switch name {
        case "search_vault": return "Searching vault..."
        case "search_vault_by_date": return "Searching by date..."
        case "search_vault_by_attribute": return "Searching by attribute..."
        case "open_file": return "Opening file..."
        case "read_file_content": return "Reading file..."
        case "create_doc": return "Creating document..."
        case "move_file": return "Moving file..."
        default: return "Working..."
        }
    }

    // MARK: - Tool Execution

    private func executeToolCall(callId: String, name: String, argumentsJSON: String) async {
        let args: [String: Any]
        if let data = argumentsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = parsed
        } else {
            args = [:]
        }

        let result: String
        if let onToolCall {
            result = await onToolCall(name, args)
        } else {
            result = "{\"error\": \"no_handler\"}"
        }

        let outputMessage: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": result
            ] as [String: Any]
        ]
        await session.provider.sendJSON(outputMessage)

        bufferLock.lock()
        functionCallBuffers.removeValue(forKey: callId)
        functionCallNames.removeValue(forKey: callId)
        let buffersEmpty = functionCallBuffers.isEmpty
        bufferLock.unlock()

        if buffersEmpty {
            await session.provider.sendJSON(["type": "response.create"])

            await MainActor.run {
                isToolExecuting = false
                currentToolActivity = nil
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    // MARK: - Helpers

    private static var todayString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

}
