import Foundation

/// Recording mode for voice creation
enum RecordingMode: String, Codable, CaseIterable, Identifiable {
    case oneSided = "One-Sided"
    case conversational = "Conversational"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneSided: return "One-Sided"
        case .conversational: return "Conversation"
        }
    }

    var description: String {
        switch self {
        case .oneSided: return "You talk, AI prompts only when needed"
        case .conversational: return "Natural back-and-forth dialogue"
        }
    }

    var icon: String {
        switch self {
        case .oneSided: return "person.wave.2"
        case .conversational: return "bubble.left.and.bubble.right"
        }
    }

    var promptID: PromptID { .voice }

    func systemPrompt(vaultURL: URL? = nil) -> String {
        PromptManager.resolve(.voice, vaultURL: vaultURL)
    }
}

/// A single turn in a voice conversation
struct TranscriptTurn: Identifiable, Codable {
    let id: UUID
    let role: Role
    let text: String
    let timestamp: Date

    init(role: Role, text: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }

    enum Role: String, Codable {
        case user
        case assistant
    }
}

/// Summarization style for document-based voice chat (used by reader voice flow)
enum SummarizationStyle: String, CaseIterable, Identifiable {
    case conversational = "Conversational"
    case interview = "Interview"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .conversational: return "Chat naturally about the document"
        case .interview: return "AI asks you structured questions"
        }
    }

    var realtimePromptID: PromptID {
        switch self {
        case .conversational: return .docConversational
        case .interview: return .docInterview
        }
    }

    /// System prompt for the realtime voice session
    func realtimeSystemPrompt(documentContent: String, documentTitle: String = "", vaultURL: URL? = nil) -> String {
        let vars: [String: String] = [
            "document_content": documentContent,
            "document_title": documentTitle
        ]
        return PromptManager.resolve(realtimePromptID, vaultURL: vaultURL, vars: vars)
    }
}

/// How to write the summary back into the document
enum EditMode: String, CaseIterable, Identifiable {
    case append = "Append"
    case rewrite = "Rewrite"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .append: return "Add summary at the end of the note"
        case .rewrite: return "Merge summary into the note content"
        }
    }
}

/// Collects conversation turns and formats them for summarization
@Observable
final class TranscriptManager {
    private(set) var turns: [TranscriptTurn] = []
    private(set) var currentAssistantText = ""

    func addUserTurn(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        turns.append(TranscriptTurn(role: .user, text: cleaned, timestamp: Date()))
    }

    func appendToAssistantText(_ delta: String) {
        currentAssistantText += delta
    }

    func finalizeAssistantTurn() {
        let cleaned = currentAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            turns.append(TranscriptTurn(role: .assistant, text: cleaned, timestamp: Date()))
        }
        currentAssistantText = ""
    }

    func clear() {
        turns = []
        currentAssistantText = ""
    }

    /// Replace entire transcript state (used by watch proxy to sync from phone)
    func replaceAll(turns newTurns: [[String: String]], currentAssistantText newAssistantText: String) {
        let parsed = newTurns.compactMap { dict -> TranscriptTurn? in
            guard let roleStr = dict["role"],
                  let role = TranscriptTurn.Role(rawValue: roleStr),
                  let text = dict["text"] else { return nil }
            return TranscriptTurn(role: role, text: text)
        }
        // Only update if different to avoid unnecessary view refreshes
        if parsed.count != turns.count || currentAssistantText != newAssistantText {
            turns = parsed
            currentAssistantText = newAssistantText
        }
    }

    /// Format full transcript as text for the summarizer
    var formattedTranscript: String {
        turns.map { turn in
            let role = turn.role == .user ? "User" : "Assistant"
            return "\(role): \(turn.text)"
        }.joined(separator: "\n\n")
    }

    var isEmpty: Bool { turns.isEmpty }
    var turnCount: Int { turns.count }
}
