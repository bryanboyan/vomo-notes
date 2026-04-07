import Foundation

/// Identifies each configurable prompt in the app
enum PromptID: String, CaseIterable, Identifiable {
    case voice
    case docConversational
    case docInterview
    case saveMyThoughts
    case saveFullSession
    case saveDensity

    var id: String { rawValue }
}

/// Metadata for a single configurable prompt
struct PromptDefinition {
    let id: PromptID
    let displayName: String
    let description: String       // plain-English explanation of when this prompt is used
    let category: String
    let fileName: String          // file inside `.vomo/prompts/`
    let defaultContent: String
    let variables: [String]       // variable names available for `{{key}}` substitution
}

// MARK: - PromptManager

/// Central registry and resolver for all AI prompts.
///
/// Resolution order:
/// 1. `.vomo/prompts/<fileName>` in the vault (user override)
/// 2. Hard-coded default from `PromptDefinition.defaultContent`
///
/// After resolution, `{{key}}` placeholders are replaced with provided variables.
enum PromptManager {

    // MARK: - Resolve

    /// Resolve a prompt: read from vault override if present, else use default.
    /// Variable substitution is applied to the result.
    static func resolve(
        _ id: PromptID,
        vaultURL: URL?,
        vars: [String: String] = [:]
    ) -> String {
        guard let def = definition(for: id) else { return "" }
        let template: String
        if let override = VomoConfig.readPromptFile(def.fileName, vaultURL: vaultURL) {
            template = VomoConfig.stripComments(override)
        } else {
            template = def.defaultContent
        }
        guard !vars.isEmpty else { return template }
        let withConditions = processConditionalBlocks(template, vars: vars)
        return VomoConfig.applyVariables(withConditions, vars: vars)
    }

    /// Process `{{#if name}}...{{/if name}}` conditional blocks.
    /// A block is kept if `vars["name"]` exists and is non-empty; otherwise the entire block is stripped.
    private static func processConditionalBlocks(_ text: String, vars: [String: String]) -> String {
        var result = text
        // Match {{#if name}}...{{/if name}} blocks (non-greedy, across newlines)
        let pattern = #"\{\{#if (\w+)\}\}\n?([\s\S]*?)\{\{/if \1\}\}\n?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        // Process from last match to first to preserve indices
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let nameRange = Range(match.range(at: 1), in: result),
                  let contentRange = Range(match.range(at: 2), in: result) else { continue }
            let name = String(result[nameRange])
            let value = vars[name] ?? ""
            if !value.isEmpty {
                // Keep the content, strip the markers
                result.replaceSubrange(fullRange, with: String(result[contentRange]))
            } else {
                // Strip the entire block
                result.replaceSubrange(fullRange, with: "")
            }
        }
        return result
    }

    /// Whether the user has a custom override file for this prompt
    static func isCustomized(_ id: PromptID, vaultURL: URL?) -> Bool {
        guard let def = definition(for: id) else { return false }
        return VomoConfig.readPromptFile(def.fileName, vaultURL: vaultURL) != nil
    }

    /// Full file URL for a prompt's override file
    static func fileURL(for id: PromptID, vaultURL: URL?) -> URL? {
        guard let vaultURL, let def = definition(for: id) else { return nil }
        return vaultURL.appendingPathComponent(".vomo/prompts/\(def.fileName)")
    }

    /// Relative path from vault root (for display)
    static func relativePath(for id: PromptID) -> String {
        guard let def = definition(for: id) else { return "" }
        return ".vomo/prompts/\(def.fileName)"
    }

    /// Create the override file with default content if it doesn't exist.
    /// Returns the file URL on success.
    @discardableResult
    static func createOverrideFile(_ id: PromptID, vaultURL: URL?) -> URL? {
        guard let vaultURL, let def = definition(for: id) else { return nil }

        let needsAccess = !vaultURL.path.hasPrefix("/var/") && !vaultURL.path.hasPrefix("/Users/")
        if needsAccess {
            guard vaultURL.startAccessingSecurityScopedResource() else { return nil }
        }
        defer { if needsAccess { vaultURL.stopAccessingSecurityScopedResource() } }

        let dirURL = vaultURL.appendingPathComponent(".vomo/prompts")
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let fileURL = dirURL.appendingPathComponent(def.fileName)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? def.defaultContent.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return fileURL
    }

    /// Save custom content to the override file for a prompt.
    static func saveOverrideContent(_ id: PromptID, content: String, vaultURL: URL?) {
        guard let vaultURL, let def = definition(for: id) else { return }

        let needsAccess = !vaultURL.path.hasPrefix("/var/") && !vaultURL.path.hasPrefix("/Users/")
        if needsAccess {
            guard vaultURL.startAccessingSecurityScopedResource() else { return }
        }
        defer { if needsAccess { vaultURL.stopAccessingSecurityScopedResource() } }

        let dirURL = vaultURL.appendingPathComponent(".vomo/prompts")
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let fileURL = dirURL.appendingPathComponent(def.fileName)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Install all default prompt files into `.vomo/prompts/` for a vault.
    /// Called when a vault is first chosen. Only creates files that don't already exist.
    static func installAllDefaults(vaultURL: URL?) {
        guard let vaultURL else { return }

        let needsAccess = !vaultURL.path.hasPrefix("/var/") && !vaultURL.path.hasPrefix("/Users/")
        if needsAccess {
            guard vaultURL.startAccessingSecurityScopedResource() else { return }
        }
        defer { if needsAccess { vaultURL.stopAccessingSecurityScopedResource() } }

        let dirURL = vaultURL.appendingPathComponent(".vomo/prompts")
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        for def in definitions {
            let fileURL = dirURL.appendingPathComponent(def.fileName)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try? def.defaultContent.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }

        // Install README if it doesn't exist
        let readmeURL = dirURL.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readmeURL.path) {
            try? promptsReadme.write(to: readmeURL, atomically: true, encoding: .utf8)
        }
    }

    /// Look up a definition by ID
    static func definition(for id: PromptID) -> PromptDefinition? {
        definitions.first { $0.id == id }
    }

    /// All definitions grouped by category (preserving order)
    static var categories: [(name: String, prompts: [PromptDefinition])] {
        var seen: [String: Int] = [:]
        var result: [(name: String, prompts: [PromptDefinition])] = []
        for def in definitions {
            if let idx = seen[def.category] {
                result[idx].prompts.append(def)
            } else {
                seen[def.category] = result.count
                result.append((name: def.category, prompts: [def]))
            }
        }
        return result
    }

    // MARK: - Definitions

    static let definitions: [PromptDefinition] = [

        // ── Voice ─────────────────────────────────────────────────────

        PromptDefinition(
            id: .voice,
            displayName: "Voice",
            description: "Your general-purpose voice assistant — search, create, and manage notes by talking.",
            category: "Voice",
            fileName: "voice.md",
            defaultContent: """
            You are a general-purpose voice assistant for the user's Obsidian vault. You can search, create, edit, move, and manage notes — or just have a natural conversation. Match the user's energy: if they want to think out loud, listen quietly; if they want to chat, engage naturally; if they want to find something, use your tools.

            CAPABILITIES:
            - Search for notes by topic, keyword, or content (search_vault)
            - Search by date range — "last week", "yesterday", "in March" (search_vault_by_date)
            - Search by metadata attribute — tag, mood, status, category, etc. (search_vault_by_attribute)
            - Combined multi-criteria search — topic + date + attributes in one call (search_vault_combined)
            - Open specific files for the user to view (open_file)
            - Read file contents to answer questions or discuss them (read_file_content)
            - Create new documents — "write a note about X", "create a doc" (create_doc)
            - Move files to different folders — "move this to Projects" (move_file)
            - Update existing notes — change properties or edit body content (update_doc)

            TOOL SELECTION GUIDE:
            1. Simple topic/keyword queries ("notes about machine learning") → search_vault
            2. Time-based queries ("notes from last week", "yesterday") → search_vault_by_date
               ALWAYS use search_vault_by_date for ANY temporal reference. NEVER use search_vault for time queries.
            3. Single attribute queries ("notes tagged X", "happy notes") → search_vault_by_attribute
            4. Complex multi-criteria queries → search_vault_combined
               Examples:
               - "meeting notes from last week tagged #work" → query="meeting", start_date/end_date, attributes={"tag":"work"}
               - "happy journal entries in March" → query="journal", start_date="2026-03-01", end_date="2026-03-31", attributes={"mood":"happy"}
            5. Too many results → refine with more criteria; too few → broaden

            {{#if auto_load}}
            AUTO-LOAD MODE (ACTIVE):
            Search results include the content of each found note (up to 50 notes).
            You can directly reference and discuss note contents from search results without calling read_file_content.
            Only use read_file_content if you need the FULL untruncated text of a specific note.
            When summarizing search results, reference specific details from the loaded content to be helpful.
            {{/if auto_load}}
            {{#if no_auto_load}}
            CONTENT ACCESS:
            Search results include titles, paths, snippets, and metadata only.
            To see the full content of a note, call read_file_content.
            If the user asks about what's IN their notes, proactively read the top results.
            {{/if no_auto_load}}

            OBSIDIAN FORMAT:
            - Notes are markdown files. Use wikilinks: [[Note Title]] or [[Note Title|alias]]
            - Tags use # prefix in frontmatter or inline: #tag

            ENTITY EXTRACTION (GRAPH VIEW):
            - ALWAYS call extract_entities after processing each user message
            - Extract people, topics, and places with connections between them

            BEHAVIOR:
            - Keep responses concise — this is voice, not text
            - Ask ONE clarifying question at a time if ambiguous
            - If the user is thinking out loud, stay quiet unless asked
            - If the user wants conversation, engage naturally
            {{#if auto_load}}
            - You already have note contents from search — summarize key findings directly
            {{/if auto_load}}
            {{#if no_auto_load}}
            - If the user wants details, use read_file_content and summarize
            {{/if no_auto_load}}
            - Today's date is {{today}}.

            The user's vault contains {{file_count}} notes.
            """,
            variables: ["file_count", "today", "auto_load", "no_auto_load"]
        ),

        // ── Document ──────────────────────────────────────────────────

        PromptDefinition(
            id: .docConversational,
            displayName: "Document — Conversational",
            description: "Chat naturally about an open document — discuss, ask questions, explore ideas.",
            category: "Document",
            fileName: "doc-conversational.md",
            defaultContent: """
            You are a voice assistant helping the user discuss the following document. Chat naturally — answer questions, share insights, and explore topics as they come up. You can suggest edits to the document; any changes require user confirmation before saving.

            IMPORTANT: Ask only ONE question at a time. Keep responses brief for voice.

            LANGUAGE: Speak and respond in the same language the user uses.

            <document title="{{document_title}}">
            {{document_content}}
            </document>
            """,
            variables: ["document_content", "document_title"]
        ),

        PromptDefinition(
            id: .docInterview,
            displayName: "Document — Interview",
            description: "AI asks you structured questions about a document, one at a time.",
            category: "Document",
            fileName: "doc-interview.md",
            defaultContent: """
            You are conducting a structured interview about this document. Your job is to ask the user questions one at a time to draw out their thoughts, opinions, and knowledge.

            RULES:
            - Ask ONE question at a time. Wait for the user's full answer before the next.
            - Work through topics from the document systematically.
            - Briefly acknowledge each answer, then ask the next question.
            - Do not summarize or restate — focus on asking clear, specific questions.
            - You can suggest edits based on the user's answers; changes require confirmation.

            LANGUAGE: Speak and respond in the same language the user uses.

            <document title="{{document_title}}">
            {{document_content}}
            </document>
            """,
            variables: ["document_content", "document_title"]
        ),

        // ── Saving ────────────────────────────────────────────────────

        PromptDefinition(
            id: .saveMyThoughts,
            displayName: "Save — My Thoughts",
            description: "Extracts only your ideas from a voice session into a clean note.",
            category: "Saving",
            fileName: "save-my-thoughts.md",
            defaultContent: """
            You are extracting the user's thoughts from a voice transcript into a clean written note.

            LANGUAGE: Write the output in the same language the user spoke. Do not translate — if they spoke Chinese, write in Chinese; if English, write in English; if mixed, preserve the mix.

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
            """,
            variables: []
        ),

        PromptDefinition(
            id: .saveFullSession,
            displayName: "Save — Full Session",
            description: "Cleans up the full conversation keeping both your words and the AI's.",
            category: "Saving",
            fileName: "save-full-session.md",
            defaultContent: """
            You are cleaning up a voice conversation transcript into readable notes.

            LANGUAGE: Write the output in the same language the user spoke. Do not translate — if they spoke Chinese, write in Chinese; if English, write in English; if mixed, preserve the mix.

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
            """,
            variables: []
        ),

        PromptDefinition(
            id: .saveDensity,
            displayName: "Save — Density",
            description: "Controls how much to compress or shorten a summary.",
            category: "Saving",
            fileName: "save-density.md",
            defaultContent: """
            COMPRESSION LEVEL: {{density_pct}}%
            - 20% = Extract only the absolute essential points. A few key sentences at most.
            - 50% = Moderate compression. Keep key ideas and important supporting details.
            - 80% = Light compression. Keep most content, remove only filler and redundancy.
            - 100% = Minimal compression. Keep nearly everything, just clean up language.
            Scale your output proportionally. Target roughly {{density_pct}}% of the meaningful content.
            """,
            variables: ["density_pct"]
        ),
    ]

    // MARK: - README

    static let promptsReadme = """
    # Vomo Prompts

    This folder contains the AI prompts that power Vomo's voice and save features. \
    Edit any file to customize how the AI behaves. Delete a file to reset it to the default.

    ## Files

    ### Voice

    **voice.md** — The voice assistant prompt. Used every time you start a voice session, \
    whether from the Voice tab, Create tab, or while reading a document. Controls how the AI \
    talks to you, what tools it can use, and how it handles documents.

    Variables (filled in automatically by the app):
    - `{{file_count}}` — number of notes in your vault
    - `{{today}}` — today's date
    - `{{document_content}}` — the document text (empty when not viewing a doc)
    - `{{document_title}}` — the document title (empty when not viewing a doc)

    Conditional blocks — show or hide sections based on app state:
    - `{{#if auto_load}}...{{/if auto_load}}` — shown when auto-load note content is ON
    - `{{#if no_auto_load}}...{{/if no_auto_load}}` — shown when auto-load is OFF

    You can use `{{#if name}}...{{/if name}}` blocks anywhere in a prompt. \
    The block is included when the variable `name` has a value, and stripped when it's empty. \
    This lets you write a single prompt with branches for different modes — \
    all visible and editable in one file.

    ### Saving

    After a voice session, you choose how to save the conversation as a note. \
    Each save style has its own prompt:

    **save-my-thoughts.md** — Extracts only your ideas from the conversation. \
    Strips out the AI's words, filler, and false starts. The result reads as if you wrote it yourself.

    **save-full-session.md** — Cleans up the full conversation (both you and the AI) \
    into a readable transcript with speaker labels.

    **save-density.md** — Controls how much to compress. Appended to the save prompt above. \
    Variable: `{{density_pct}}` (0-100).

    ## Tips

    - Keep prompts concise — long prompts use more tokens and can make the AI slower to respond.
    - Test changes by starting a voice session after saving your edit.
    - If something breaks, just delete the file. Vomo will recreate it with the default next time.
    """
}
