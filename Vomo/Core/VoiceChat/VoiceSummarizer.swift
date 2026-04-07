import Foundation

/// Save style determines what to extract from the transcript
enum SaveStyle: String, CaseIterable, Identifiable {
    case myThoughts = "My Thoughts"
    case fullSession = "Full Session"
    case rawTranscript = "Raw Transcript"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .myThoughts: return "Extract your ideas, strip everything else"
        case .fullSession: return "Clean up both sides, keep the flow"
        case .rawTranscript: return "Unprocessed transcript as-is"
        }
    }

    var icon: String {
        switch self {
        case .myThoughts: return "brain.head.profile"
        case .fullSession: return "text.bubble"
        case .rawTranscript: return "text.quote"
        }
    }

    var promptID: PromptID? {
        switch self {
        case .myThoughts: return .saveMyThoughts
        case .fullSession: return .saveFullSession
        case .rawTranscript: return nil
        }
    }

    func summarizationPrompt(vaultURL: URL? = nil) -> String {
        guard let pid = promptID else { return "" }
        return PromptManager.resolve(pid, vaultURL: vaultURL)
    }
}

/// Save action determines how the output is used
enum SaveAction {
    case createNew
    case appendToDoc
    case replaceDoc(existingBody: String)

    var modifier: String {
        switch self {
        case .createNew:
            return "\nSAVE ACTION: Output a standalone note."
        case .appendToDoc:
            return "\nSAVE ACTION: Output a section suitable for appending to an existing document. Do not repeat the document title."
        case .replaceDoc(let existingBody):
            return """
            \nSAVE ACTION: Merge the conversation insights into the existing document below, \
            preserving its structure and headings. Integrate new information naturally. \
            Do NOT add any frontmatter (YAML between --- delimiters). Output only the merged document body in markdown. \
            LANGUAGE: Write in the same language as the existing document and conversation — do not translate.

            <existing_document>
            \(existingBody)
            </existing_document>
            """
        }
    }
}

/// Uses a text model API to summarize voice conversation transcripts
struct VoiceSummarizer {

    // MARK: - Public API

    /// Summarize a transcript using the specified save style
    /// - Parameters:
    ///   - transcript: The voice conversation transcript
    ///   - style: What to extract (my thoughts only, or full session)
    ///   - density: 0.2 (extreme compression) to 1.0 (keep nearly everything)
    ///   - action: How to use the output (create new, append, or replace/merge)
    ///   - vaultURL: The vault URL for prompt resolution
    static func summarize(
        transcript: String,
        style: SaveStyle,
        density: Double = 0.5,
        action: SaveAction = .createNew,
        vaultURL: URL? = nil
    ) async throws -> String {
        guard style != .rawTranscript else { return transcript }

        let pct = Int(density * 100)
        let basePrompt = style.summarizationPrompt(vaultURL: vaultURL)
        let densityInstruction = "\n" + PromptManager.resolve(
            .saveDensity, vaultURL: vaultURL, vars: ["density_pct": "\(pct)"]
        )
        let actionModifier = action.modifier

        return try await callTextAPI(
            systemPrompt: basePrompt + densityInstruction + actionModifier,
            userMessage: "Here is the voice transcript:\n\n\(transcript)"
        )
    }

    /// Apply summary to a document file
    static func applyToDocument(
        fileURL: URL,
        summary: String,
        editMode: EditMode,
        vaultURL: URL? = nil
    ) async throws {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let (frontmatter, body) = MarkdownParser.extractFrontmatter(content)

        let newContent: String
        switch editMode {
        case .append:
            let timestamp = Self.formattedTimestamp()
            let appendSection = "\n\n---\n## Voice Chat — \(timestamp)\n\n\(summary)\n"
            newContent = content + appendSection

        case .rewrite:
            let mergedBody = try await summarize(
                transcript: summary,
                style: .fullSession,
                density: 1.0,
                action: .replaceDoc(existingBody: body),
                vaultURL: vaultURL
            )
            if let fm = frontmatter {
                newContent = "---\n\(fm)\n---\n\(mergedBody)"
            } else {
                newContent = mergedBody
            }
        }

        try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Private — Vendor Dispatch

    private static func callTextAPI(
        systemPrompt: String,
        userMessage: String,
        temperature: Double = 0.3
    ) async throws -> String {
        let vendor = VoiceSettings.shared.textModelVendor
        guard let apiKey = APIKeychain.load(vendor: vendor.keychainKey) else {
            throw SummarizerError.apiError("No API key configured for \(vendor.displayName). Add one in Settings → Providers.")
        }

        switch vendor {
        case .xai, .openai:
            return try await callOpenAICompatible(
                endpoint: vendor.endpoint,
                model: vendor.model,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                apiKey: apiKey,
                temperature: temperature
            )
        case .anthropic:
            return try await callAnthropic(
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                apiKey: apiKey,
                temperature: temperature
            )
        }
    }

    private static func callOpenAICompatible(
        endpoint: String,
        model: String,
        systemPrompt: String,
        userMessage: String,
        apiKey: String,
        temperature: Double
    ) async throws -> String {
        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "temperature": temperature
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            DiagnosticLogger.shared.error("Summarizer", "API returned status \(statusCode)")
            throw SummarizerError.apiError("API returned non-200 status (\(statusCode))")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            DiagnosticLogger.shared.error("Summarizer", "Failed to parse API response")
            throw SummarizerError.parseError
        }

        return content
    }

    private static func callAnthropic(
        systemPrompt: String,
        userMessage: String,
        apiKey: String,
        temperature: Double
    ) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": TextModelVendor.anthropic.model,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userMessage]
            ],
            "temperature": temperature,
            "max_tokens": 4096
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            DiagnosticLogger.shared.error("Summarizer", "Anthropic API returned status \(statusCode)")
            throw SummarizerError.apiError("Anthropic API returned non-200 status (\(statusCode))")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]],
              let firstBlock = contentArray.first,
              let text = firstBlock["text"] as? String else {
            DiagnosticLogger.shared.error("Summarizer", "Failed to parse Anthropic response")
            throw SummarizerError.parseError
        }

        return text
    }

    private static func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return formatter.string(from: Date()) + " PT"
    }
}

enum SummarizerError: Error, LocalizedError {
    case apiError(String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .apiError(let msg): return msg
        case .parseError: return "Failed to parse API response"
        }
    }
}
