import Foundation

/// Uses Grok text API to summarize a voice conversation transcript
struct VoiceSummarizer {

    // MARK: - Creation Flow (SaveMode-based)

    /// Summarize a transcript using the specified save mode (for voice creation)
    /// - density: 0.2 (extreme compression) to 1.0 (keep nearly everything)
    static func summarize(
        transcript: String,
        saveMode: SaveMode,
        density: Double = 0.5,
        apiKey: String,
        vaultURL: URL? = nil
    ) async throws -> String {
        guard saveMode != .rawTranscript else { return transcript }

        let pct = Int(density * 100)
        var densityInstruction = """

        COMPRESSION LEVEL: \(pct)%
        - 20% = Extract only the absolute essential points. A few key sentences at most.
        - 50% = Moderate compression. Keep key ideas and important supporting details.
        - 80% = Light compression. Keep most content, remove only filler and redundancy.
        - 100% = Minimal compression. Keep nearly everything, just clean up language.
        Scale your output proportionally. Target roughly \(pct)% of the meaningful content.
        """

        // Check for density section override in summarization.txt
        if let override = VomoConfig.readPromptFile("summarization.txt", vaultURL: vaultURL) {
            let sections = VomoConfig.parseSections(override)
            if let densitySection = sections["density"], !densitySection.isEmpty {
                densityInstruction = "\n" + VomoConfig.applyVariables(densitySection, vars: ["density_pct": "\(pct)"])
            }
        }

        return try await callGrok(
            systemPrompt: saveMode.summarizationPrompt(vaultURL: vaultURL) + densityInstruction,
            userMessage: "Here is the voice transcript:\n\n\(transcript)",
            apiKey: apiKey
        )
    }

    // MARK: - Document Voice Chat (SummarizationStyle-based)

    /// Summarize a transcript using the specified style (for search voice flow)
    static func summarize(
        transcript: String,
        style: SummarizationStyle,
        apiKey: String,
        vaultURL: URL? = nil
    ) async throws -> String {
        return try await callGrok(
            systemPrompt: style.summarizationPrompt(vaultURL: vaultURL),
            userMessage: "Here is the transcript to summarize:\n\n\(transcript)",
            apiKey: apiKey
        )
    }

    /// Rewrite a document by merging existing content with summarized conversation
    static func rewriteDocument(
        existingBody: String,
        summary: String,
        apiKey: String,
        vaultURL: URL? = nil
    ) async throws -> String {
        var rewritePrompt = """
        You are a document editor. Merge the existing document content with the new conversation summary \
        into a cohesive, well-structured document. Preserve the existing content's structure and headings. \
        Integrate the new information naturally. Do NOT add any frontmatter (YAML between --- delimiters). \
        Output only the merged document body in markdown.
        """

        // Check for document_rewrite section in summarization.txt
        if let override = VomoConfig.readPromptFile("summarization.txt", vaultURL: vaultURL) {
            let sections = VomoConfig.parseSections(override)
            if let rewriteSection = sections["document_rewrite"], !rewriteSection.isEmpty {
                rewritePrompt = rewriteSection
            }
        }

        return try await callGrok(
            systemPrompt: rewritePrompt,
            userMessage: """
            ## Existing Document
            \(existingBody)

            ## New Conversation Summary
            \(summary)

            Please merge these into a single cohesive document.
            """,
            apiKey: apiKey
        )
    }

    /// Apply summary to a document file
    static func applyToDocument(
        fileURL: URL,
        summary: String,
        editMode: EditMode,
        apiKey: String,
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
            let mergedBody = try await rewriteDocument(
                existingBody: body,
                summary: summary,
                apiKey: apiKey,
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

    // MARK: - Private

    private static func callGrok(
        systemPrompt: String,
        userMessage: String,
        apiKey: String,
        temperature: Double = 0.3
    ) async throws -> String {
        let url = URL(string: "https://api.x.ai/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "grok-3-fast",
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
