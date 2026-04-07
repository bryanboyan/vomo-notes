import Foundation
import UIKit

/// A found file from voice search, wrapping VaultFile with match context
struct FoundFile: Identifiable {
    let id = UUID()
    let file: VaultFile
    let reason: String      // e.g. "Matched search for 'machine learning'"
    let snippet: String     // relevant content snippet
    let isHighlighted: Bool // true if AI explicitly opened this file
}

/// Composition wrapper around RealtimeVoiceProvider that adds tool-use support
/// for agentic voice search. Owned by SearchTab as @State so it survives
/// NavigationStack pushes to ReaderView.
///
///   Tool calling flow:
///   User speaks → provider transcribes → provider calls tool
///        ↓
///   response.function_call_arguments.done
///        ↓
///   App executes tool locally (search_vault / open_file / read_file_content)
///        ↓
///   conversation.item.create (function_call_output) → response.create
///        ↓
///   Provider speaks result to user
///
@Observable
final class AgentVoiceService: Identifiable {
    let id = UUID()
    private(set) var provider: RealtimeVoiceProvider
    private(set) var foundFiles: [FoundFile] = []
    private(set) var isToolExecuting = false
    private(set) var currentToolActivity: String?
    private(set) var inputMode: VoiceInputMode = .interactive
    private(set) var isPTTActive = false  // true while PTT button is held down

    /// Graph manager for the dynamic voice conversation graph
    let graphManager = VoiceGraphManager()

    /// Callback for tool execution — provided by the owning view.
    /// Parameters: tool name, parsed arguments dictionary. Returns JSON string result.
    var onToolCall: ((String, [String: Any]) async -> String)?

    // Accumulator for streaming function call arguments
    // Accessed from WebSocket background thread — synchronized via lock
    private let bufferLock = NSLock()
    private var functionCallBuffers: [String: String] = [:]  // call_id → accumulated args
    private var functionCallNames: [String: String] = [:]    // call_id → function name

    var state: VoiceChatState { provider.state }
    var transcript: TranscriptManager { provider.transcript }

    // MARK: - Settings (delegated to VoiceSettings)

    static var savedVoice: String {
        get { VoiceSettings.shared.selectedVoice }
        set { VoiceSettings.shared.selectedVoice = newValue }
    }

    init() {
        let settings = VoiceSettings.shared
        provider = VoiceProviderFactory.makeRealtime(vendor: settings.realtimeVendor)
        provider.voice = settings.selectedVoice
        provider.onMessage = { [weak self] type, json in
            self?.handleMessage(type, json: json) ?? false
        }
    }

    // MARK: - Voice Input Mode

    func switchToInteractive() {
        inputMode = .interactive
        isPTTActive = false
        provider.isCapturingAudio = true
        provider.updateTurnDetection(enabled: true)
    }

    func switchToPTT() {
        inputMode = .ptt
        isPTTActive = false
        provider.isCapturingAudio = false
        provider.updateTurnDetection(enabled: false)
    }

    func startPTT() {
        guard inputMode == .ptt else { return }
        isPTTActive = true
        provider.clearAudioBuffer()
        provider.isCapturingAudio = true
    }

    func stopPTT() {
        guard inputMode == .ptt else { return }
        isPTTActive = false
        provider.isCapturingAudio = false
        provider.commitAudioBuffer()
    }

    // MARK: - Connect / Disconnect

    func connect(apiKey: String, fileCount: Int, vaultURL: URL? = nil) {
        provider.voice = VoiceSettings.shared.selectedVoice
        provider.tools = Self.toolDefinitions

        let autoLoad = VoiceSettings.shared.autoLoadNoteContent

        let vars: [String: String] = [
            "file_count": "\(fileCount)",
            "today": Self.todayString,
            "auto_load": autoLoad ? "true" : "",
            "no_auto_load": autoLoad ? "" : "true"
        ]

        var systemPrompt = PromptManager.resolve(.voice, vaultURL: vaultURL, vars: vars)

        // Append vault-level voice instructions from .vomo/voice_instructions.txt
        if let voiceInstructions = VomoConfig.voiceInstructions(vaultURL: vaultURL) {
            systemPrompt += "\n\nADDITIONAL INSTRUCTIONS:\n\(voiceInstructions)"
        }

        // Append folder scope constraints
        let sm = SettingsManager.shared
        if !sm.voiceSearchIncludeFolders.isEmpty {
            let list = sm.voiceSearchIncludeFolders.joined(separator: ", ")
            systemPrompt += "\n\nSEARCH SCOPE: Restricted to folders: \(list). Only search within these folders."
        } else if !sm.voiceSearchExcludeFolders.isEmpty {
            let list = sm.voiceSearchExcludeFolders.joined(separator: ", ")
            systemPrompt += "\n\nSEARCH SCOPE: Excludes folders: \(list). Do not search in these folders."
        }

        provider.connect(apiKey: apiKey, documentContent: "", systemInstructions: systemPrompt)
        CrashReporter.shared.voiceSessionStarted()
    }

    func disconnect() {
        let lastState = provider.state
        provider.disconnect()
        bufferLock.lock()
        functionCallBuffers.removeAll()
        functionCallNames.removeAll()
        bufferLock.unlock()
        currentToolActivity = nil
        isToolExecuting = false
        graphManager.clear()
        CrashReporter.shared.voiceSessionEnded(lastState: lastState)
    }

    // MARK: - Text Input

    /// Send a text message via the realtime API (conversation.item.create + response.create)
    func sendTextMessage(_ text: String) {
        guard !text.isEmpty else { return }

        // Add to transcript immediately
        transcript.addUserTurn(text)

        Task {
            // Create a user message item
            let item: [String: Any] = [
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": text]
                    ]
                ] as [String: Any]
            ]
            await provider.sendJSON(item)

            // Trigger a response
            await provider.sendJSON(["type": "response.create"])
        }
    }

    // MARK: - Found Files Management

    func addFoundFile(_ file: VaultFile, reason: String, snippet: String, highlighted: Bool = false) {
        // Avoid duplicates
        guard !foundFiles.contains(where: { $0.file.id == file.id }) else {
            // If already exists, update highlight if needed
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

    func clearFoundFiles() {
        foundFiles.removeAll()
    }

    // MARK: - Message Interception

    /// Returns true if the message was handled (tool call related)
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
            print("🔧 [TOOL CALL] \(name) | callId=\(callId) | args=\(args)")

            Task { @MainActor in
                isToolExecuting = true
                currentToolActivity = toolActivityMessage(for: name)
            }

            Task {
                await executeToolCall(callId: callId, name: name, argumentsJSON: args)
            }
            return true

        case "response.output_item.done":
            // Check if this is a function_call item completion
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
        case "search_vault_combined": return "Searching vault..."
        case "open_file": return "Opening file..."
        case "read_file_content": return "Reading file..."
        case "create_doc": return "Creating document..."
        case "move_file": return "Moving file..."
        case "extract_entities": return "Mapping conversation..."
        default: return "Working..."
        }
    }

    private static var todayString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    // MARK: - Tool Execution

    private func executeToolCall(callId: String, name: String, argumentsJSON: String) async {
        // Parse arguments
        let args: [String: Any]
        if let data = argumentsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = parsed
        } else {
            args = [:]
        }

        // Execute via callback
        let result: String
        if let onToolCall {
            result = await onToolCall(name, args)
        } else {
            result = "{\"error\": \"no_handler\"}"
        }
        let truncResult = result.count > 500 ? String(result.prefix(500)) + "..." : result
        print("🔧 [TOOL RESULT] \(name) | \(result.count) chars | \(truncResult)")

        // Send function call output back to provider
        let outputMessage: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": result
            ] as [String: Any]
        ]
        await provider.sendJSON(outputMessage)

        // Clean up buffer
        bufferLock.lock()
        functionCallBuffers.removeValue(forKey: callId)
        functionCallNames.removeValue(forKey: callId)
        let buffersEmpty = functionCallBuffers.isEmpty
        bufferLock.unlock()

        // If no more pending tool calls, trigger response and clear activity
        if buffersEmpty {
            let responseCreate: [String: Any] = [
                "type": "response.create"
            ]
            await provider.sendJSON(responseCreate)

            await MainActor.run {
                isToolExecuting = false
                currentToolActivity = nil
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    // MARK: - Tool Definitions

    static let toolDefinitions: [[String: Any]] = [
        [
            "type": "function",
            "name": "search_vault",
            "description": "Search the user's vault for notes matching a text query. Returns titles, paths, content snippets, metadata, and (when auto-load is on) note content. Use for keyword/topic searches. Returns up to 50 results ranked by relevance.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Search terms to find relevant notes"
                    ]
                ],
                "required": ["query"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "type": "function",
            "name": "search_vault_by_date",
            "description": "Search for notes within a date range. Use for time-based queries like 'last week', 'yesterday', 'in March'. Returns notes sorted by date, newest first.",
            "parameters": [
                "type": "object",
                "properties": [
                    "start_date": [
                        "type": "string",
                        "description": "Start date in YYYY-MM-DD format"
                    ],
                    "end_date": [
                        "type": "string",
                        "description": "End date in YYYY-MM-DD format"
                    ]
                ],
                "required": ["start_date", "end_date"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "type": "function",
            "name": "search_vault_by_attribute",
            "description": "Search for notes by a metadata attribute. Works with any frontmatter property (mood, status, type, category, etc.) or tags. Examples: attribute='mood' value='happy', attribute='tag' value='meeting', attribute='status' value='draft'.",
            "parameters": [
                "type": "object",
                "properties": [
                    "attribute": [
                        "type": "string",
                        "description": "The attribute name to search by (e.g. 'mood', 'tag', 'status', 'type', 'category')"
                    ],
                    "value": [
                        "type": "string",
                        "description": "The value to match for the attribute"
                    ]
                ],
                "required": ["attribute", "value"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "type": "function",
            "name": "search_vault_combined",
            "description": """
                Multi-criteria search combining text, date range, and metadata attributes in a single call. \
                Use when the user's query involves multiple filters, e.g. "meeting notes from last week tagged #work" \
                or "happy journal entries in March about travel". Returns up to 50 results ranked by relevance. \
                All parameters are optional but at least one must be provided.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Optional text/keyword search terms"
                    ],
                    "start_date": [
                        "type": "string",
                        "description": "Optional start date in YYYY-MM-DD format"
                    ],
                    "end_date": [
                        "type": "string",
                        "description": "Optional end date in YYYY-MM-DD format"
                    ],
                    "attributes": [
                        "type": "object",
                        "description": "Optional key-value pairs to filter by metadata. Keys are property names (mood, tag, status, type, category). Example: {\"mood\": \"happy\", \"tag\": \"work\"}"
                    ]
                ],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any],
        [
            "type": "function",
            "name": "open_file",
            "description": "Open a specific file for the user. Navigates directly to the file so the user can read it.",
            "parameters": [
                "type": "object",
                "properties": [
                    "filename": [
                        "type": "string",
                        "description": "The title or path of the file to show"
                    ]
                ],
                "required": ["filename"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "type": "function",
            "name": "read_file_content",
            "description": "Read the full content of a vault file so you can discuss it, answer questions about it, or compare it with other files.",
            "parameters": [
                "type": "object",
                "properties": [
                    "filename": [
                        "type": "string",
                        "description": "The title or path of the file to read"
                    ]
                ],
                "required": ["filename"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "type": "function",
            "name": "create_doc",
            "description": "Create a new markdown document in the vault. Use when the user asks to create a note, write something down, or save information. Use [[Note Title]] wikilinks to reference other notes and [[Note Title|alias]] for display text.",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "The title for the new document (becomes the filename)"
                    ],
                    "content": [
                        "type": "string",
                        "description": "The markdown content to write into the document"
                    ],
                    "folder": [
                        "type": "string",
                        "description": "Optional folder path (e.g. 'Projects' or 'Daily Notes'). Omit for vault root."
                    ]
                ],
                "required": ["title", "content"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "type": "function",
            "name": "move_file",
            "description": "Move an existing file to a different folder in the vault. Use when the user asks to move, reorganize, or relocate a note.",
            "parameters": [
                "type": "object",
                "properties": [
                    "filename": [
                        "type": "string",
                        "description": "The title or path of the file to move"
                    ],
                    "destination_folder": [
                        "type": "string",
                        "description": "The folder path to move the file to (e.g. 'Projects' or 'Archive'). Empty string for vault root."
                    ]
                ],
                "required": ["filename", "destination_folder"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "type": "function",
            "name": "extract_entities",
            "description": """
                Extract people, topics, and places mentioned in the conversation so far. \
                Call this tool AUTOMATICALLY after every user message to keep the conversation graph updated. \
                Identify the key entities the user mentioned and any connections between them. \
                For example, if the user says "Find my notes about the meeting with John about the Berlin project", \
                extract entities: John (person), meeting (topic), Berlin project (topic), Berlin (place), \
                and connections: John-meeting, John-Berlin project, meeting-Berlin project.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "entities": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string", "description": "Entity name"],
                                "type": ["type": "string", "enum": ["person", "topic", "place"], "description": "Entity type"]
                            ],
                            "required": ["name", "type"]
                        ] as [String: Any],
                        "description": "List of entities mentioned in the conversation"
                    ] as [String: Any],
                    "connections": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "from": ["type": "string", "description": "Source entity name"],
                                "to": ["type": "string", "description": "Target entity name"]
                            ],
                            "required": ["from", "to"]
                        ] as [String: Any],
                        "description": "Connections between entities"
                    ] as [String: Any]
                ],
                "required": ["entities"]
            ] as [String: Any]
        ] as [String: Any],
        [
            "type": "function",
            "name": "update_doc",
            "description": """
                Update an existing note's frontmatter properties and/or body content. \
                Use when the user asks to change, edit, set, or update a note's metadata (mood, tags, date, status, etc.) or body text. \
                Properties are written to YAML frontmatter with correct types inferred from the vault. \
                For content, you can replace the entire body, append to it, or prepend to it.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "filename": [
                        "type": "string",
                        "description": "The title or path of the file to update"
                    ],
                    "properties": [
                        "type": "object",
                        "description": "Key-value pairs to set in frontmatter. Values can be strings, numbers, booleans, or arrays of strings. Use [[Title]] for wikilinks. Set a key to null to remove it."
                    ],
                    "content": [
                        "type": "string",
                        "description": "New body content (markdown). Only provide if the user wants to change the body text."
                    ],
                    "mode": [
                        "type": "string",
                        "enum": ["replace", "append", "prepend"],
                        "description": "How to apply content: 'replace' overwrites body (default), 'append' adds to end, 'prepend' adds to beginning."
                    ]
                ],
                "required": ["filename"]
            ] as [String: Any]
        ] as [String: Any]
    ]
}
