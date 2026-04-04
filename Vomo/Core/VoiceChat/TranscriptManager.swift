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

    func systemPrompt(customRules: String = "", vaultURL: URL? = nil) -> String {
        // Check for .vomo/prompts/recording.txt override
        if let override = VomoConfig.readPromptFile("recording.txt", vaultURL: vaultURL) {
            let sections = VomoConfig.parseSections(override)
            let sectionKey: String
            switch self {
            case .oneSided: sectionKey = "one_sided"
            case .conversational: sectionKey = "conversational"
            }
            if let sectionContent = sections[sectionKey], !sectionContent.isEmpty {
                if customRules.isEmpty { return sectionContent }
                return sectionContent + "\n\nADDITIONAL INSTRUCTIONS FROM USER:\n\(customRules)"
            }
            // If file exists but section not found, check for unsectioned content
            if let unsectioned = sections[""], !unsectioned.isEmpty {
                if customRules.isEmpty { return unsectioned }
                return unsectioned + "\n\nADDITIONAL INSTRUCTIONS FROM USER:\n\(customRules)"
            }
        }

        let base: String
        switch self {
        case .oneSided:
            base = """
            You are a silent note-taking assistant. The user is speaking their thoughts aloud.

            RULES:
            - Do NOT speak unless the user explicitly asks you a question or pauses expecting a prompt.
            - When you do speak, ask exactly ONE short follow-up question to help the user go deeper on what they just said.
            - Never summarize, restate, or reflect back what the user said.
            - Never add your own opinions or commentary.
            - Never use filler like "That's great!" or "Interesting point!"
            - Your only job is to help the user keep talking and thinking.
            - If the user seems done with a topic, ask "Is there anything else?" and stop.
            """
        case .conversational:
            base = """
            You are having a natural conversation with the user. Listen actively and engage with their ideas.

            RULES:
            - Respond naturally to what the user says.
            - Ask follow-up questions when something is interesting or unclear.
            - Keep responses concise — this is a voice conversation, not an essay.
            - Match the user's energy and tone.
            - Don't lecture or monologue. Short responses, then let the user talk.
            """
        }

        if customRules.isEmpty { return base }
        return base + "\n\nADDITIONAL INSTRUCTIONS FROM USER:\n\(customRules)"
    }
}

/// Save mode for converting transcripts to notes
enum SaveMode: String, Codable, CaseIterable, Identifiable {
    case userThoughts = "User Thoughts"
    case interactionNotes = "Interaction Notes"
    case rawTranscript = "Raw Transcript"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .userThoughts: return "Extract your ideas, strip everything else"
        case .interactionNotes: return "Clean up both sides, keep the flow"
        case .rawTranscript: return "Unprocessed transcript as-is"
        }
    }

    var icon: String {
        switch self {
        case .userThoughts: return "brain.head.profile"
        case .interactionNotes: return "text.bubble"
        case .rawTranscript: return "text.quote"
        }
    }

    /// Default save mode for a given recording mode
    static func defaultMode(for recording: RecordingMode) -> SaveMode {
        switch recording {
        case .oneSided: return .userThoughts
        case .conversational: return .interactionNotes
        }
    }

    func summarizationPrompt(vaultURL: URL? = nil) -> String {
        // Check for .vomo/prompts/summarization.txt override
        if let override = VomoConfig.readPromptFile("summarization.txt", vaultURL: vaultURL) {
            let sections = VomoConfig.parseSections(override)
            let sectionKey: String
            switch self {
            case .userThoughts: sectionKey = "user_thoughts"
            case .interactionNotes: sectionKey = "interaction_notes"
            case .rawTranscript: sectionKey = ""
            }
            if !sectionKey.isEmpty, let sectionContent = sections[sectionKey], !sectionContent.isEmpty {
                return sectionContent
            }
        }

        switch self {
        case .userThoughts:
            return """
            You are extracting the user's thoughts from a voice transcript into a clean written note.

            INPUT: A transcript between a user and an assistant.

            YOUR TASK:
            1. Extract ONLY the user's substantive ideas, plans, feelings, and decisions.
            2. Organize them into clear sections with markdown headers if there are distinct topics.
            3. Strip away completely:
               - All assistant questions and responses
               - Filler words (um, uh, like, you know, so, basically)
               - False starts and self-corrections
               - Conversational pleasantries (hello, thanks, yeah)
               - Repeated statements (keep the clearest version)
               - Meta-commentary about the recording itself
            4. Preserve the user's voice and word choices where they are distinctive.
            5. Use first person ("I want to..." not "The user wants to...").

            OUTPUT FORMAT:
            - Start with a markdown H1 title (# Title) that captures the primary topic or intent.
            - The title must be short and specific — NOT generic like "Voice Note" or "My Thoughts" or "Summary".
            - Good titles: "Trip to Taipei — Grandfather's Last Wish", "API Redesign: Moving to GraphQL"
            - After the title, write content directly. NO preamble, NO "Here's a summary", NO meta-text.
            - Use ## headers to separate distinct topics.
            - Use bullet points for lists, full paragraphs for narratives.
            - The note should read as if the user wrote it themselves.
            """
        case .interactionNotes:
            return """
            You are cleaning up a voice conversation transcript into readable notes.

            YOUR TASK:
            1. Remove ONLY:
               - Audio artifacts: "um", "uh", "hmm", "like" (as filler), false starts
               - Connection noise: "hello?", "can you hear me?", "sorry say that again"
               - Exact duplicate statements (keep the first or clearest version)
            2. Keep EVERYTHING ELSE — both user and assistant contributions.
            3. Format as a clean conversation with clear speaker labels.
            4. Preserve the chronological flow.

            OUTPUT FORMAT:
            - Start with a markdown H1 title (# Title) that captures the conversation topic.
            - The title must be short and specific — NOT generic.
            - NO preamble or meta-text. Start directly with the title then content.
            - Use **User:** and **Assistant:** labels for each turn.
            - Group related exchanges under ## topic headers if the conversation shifts topics.
            - Clean up grammar minimally — keep the conversational feel.
            """
        case .rawTranscript:
            return "" // unused — raw transcript returned as-is
        }
    }

    var summarizationPrompt: String {
        summarizationPrompt()
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

/// Summarization style for document-based voice chat (used by search voice flow)
enum SummarizationStyle: String, CaseIterable, Identifiable {
    case interview = "Interview"
    case query = "Query"
    case conversational = "Conversational"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .interview: return "Agent asks questions, focus on your answers"
        case .query: return "You ask questions, focus on agent's answers"
        case .conversational: return "Balanced summary of both sides"
        }
    }

    /// System prompt for the realtime voice session (how Grok should behave during the conversation)
    func realtimeSystemPrompt(documentContent: String, documentTitle: String = "", vaultURL: URL? = nil) -> String {
        // Check for .vomo/prompts/document_chat.txt override
        if let override = VomoConfig.readPromptFile("document_chat.txt", vaultURL: vaultURL) {
            let sections = VomoConfig.parseSections(override)
            let vars: [String: String] = [
                "document_content": documentContent,
                "document_title": documentTitle
            ]
            let sectionKey: String
            switch self {
            case .interview: sectionKey = "interview"
            case .query: sectionKey = "query"
            case .conversational: sectionKey = "conversational"
            }
            // Try style-specific section, then "base" + style section, then fallback section
            if let sectionContent = sections[sectionKey], !sectionContent.isEmpty {
                let baseContent = sections["base"].map { $0 + "\n\n" } ?? ""
                return VomoConfig.applyVariables(baseContent + sectionContent, vars: vars)
            }
            if let fallback = sections["fallback"], !fallback.isEmpty {
                return VomoConfig.applyVariables(fallback, vars: vars)
            }
            // Unsectioned content
            if let unsectioned = sections[""], !unsectioned.isEmpty {
                return VomoConfig.applyVariables(unsectioned, vars: vars)
            }
        }

        let base = """
        You are a voice assistant helping the user with the following document. \
        Keep your responses concise and natural for voice conversation. \
        IMPORTANT: Always ask only ONE question at a time. Wait for the user to respond before moving on. \
        Never list multiple questions in a single turn. Keep track of what you have already covered.

        <document>
        \(documentContent)
        </document>
        """

        switch self {
        case .interview:
            return base + """

            \nYou are conducting an interview with the user about this document. \
            Your job is to ask the user questions to draw out their thoughts, opinions, and knowledge. \
            Ask ONE question at a time. Wait for the user's full answer before asking the next question. \
            Keep a mental checklist of topics to cover from the document, and work through them one by one. \
            Do not summarize or restate — focus on asking clear, specific questions. \
            After the user answers, briefly acknowledge their point, then ask the next question.
            """
        case .query:
            return base + """

            \nThe user wants to ask you questions about this document. \
            Answer each question concisely and accurately based on the document content. \
            If the document doesn't contain the answer, say so. \
            After answering, pause and wait for the user's next question. \
            Do not volunteer additional questions or topics unless asked.
            """
        case .conversational:
            return base + """

            \nHave a natural conversation with the user about this document. \
            Answer questions, share insights, and discuss topics as they come up. \
            If you want to explore a topic, ask ONE follow-up question at a time. \
            Keep responses brief — this is a voice conversation, not an essay.
            """
        }
    }

    /// System prompt for the summarization API call (how to summarize the transcript)
    func summarizationPrompt(vaultURL: URL? = nil) -> String {
        // Check for .vomo/prompts/summarization.txt override
        if let override = VomoConfig.readPromptFile("summarization.txt", vaultURL: vaultURL) {
            let sections = VomoConfig.parseSections(override)
            let sectionKey: String
            switch self {
            case .interview: sectionKey = "interview_summary"
            case .query: sectionKey = "query_summary"
            case .conversational: sectionKey = "conversational_summary"
            }
            if let sectionContent = sections[sectionKey], !sectionContent.isEmpty {
                return sectionContent
            }
        }

        switch self {
        case .interview:
            return """
            Summarize this voice conversation transcript in interview style. \
            The assistant was conducting an interview by asking questions. \
            Format: list each question the assistant asked, followed by the user's key points in detail. \
            Remove all filler words, false starts, and conversational pleasantries. \
            Be concise but preserve the substance of the user's answers.
            """
        case .query:
            return """
            Summarize this voice conversation transcript in Q&A style. \
            The user was asking questions and the assistant was answering. \
            Format: show each user query briefly, then the assistant's answer in succinct detail. \
            Remove filler words and conversational pleasantries. \
            Focus on the informational content of the answers.
            """
        case .conversational:
            return """
            Summarize this voice conversation transcript. \
            Capture key points from both the user and the assistant. \
            Remove all filler ("can you hear me", "um", "so basically", "yeah", greetings, goodbyes). \
            Keep the summary concise and information-dense while preserving both perspectives.
            """
        }
    }

    /// Convenience property for backward compatibility (uses default, no vault override)
    var systemPrompt: String {
        summarizationPrompt()
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
