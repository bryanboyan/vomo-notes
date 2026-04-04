import Foundation

/// Reads optional config files from `.vomo/` inside the vault root.
/// All reads are best-effort — missing or unreadable files return nil.
enum VomoConfig {
    /// Read a text file from `.vomo/<filename>` in the vault.
    /// Returns nil if the vault URL is nil, the file doesn't exist, or it can't be read.
    static func readFile(_ filename: String, vaultURL: URL?) -> String? {
        guard let vaultURL else { return nil }

        let needsAccess = !vaultURL.path.hasPrefix("/var/") && !vaultURL.path.hasPrefix("/Users/")
        if needsAccess {
            guard vaultURL.startAccessingSecurityScopedResource() else { return nil }
        }
        defer { if needsAccess { vaultURL.stopAccessingSecurityScopedResource() } }

        let fileURL = vaultURL.appendingPathComponent(".vomo/\(filename)")
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Additional voice instructions from `.vomo/voice_instructions.txt`.
    static func voiceInstructions(vaultURL: URL?) -> String? {
        readFile("voice_instructions.txt", vaultURL: vaultURL)
    }

    /// Additional STT instructions from `.vomo/stt_instructions.txt`.
    static func sttInstructions(vaultURL: URL?) -> String? {
        readFile("stt_instructions.txt", vaultURL: vaultURL)
    }

    // MARK: - Prompt Overrides

    /// Read a prompt file from `.vomo/prompts/<filename>`.
    static func readPromptFile(_ filename: String, vaultURL: URL?) -> String? {
        readFile("prompts/\(filename)", vaultURL: vaultURL)
    }

    /// Strip comment lines (starting with `#`) and blank lines from the top of text.
    static func stripComments(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let start = lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        } ?? lines.endIndex
        return lines[start...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse YAML-style sections from a prompt file.
    ///
    /// Format:
    /// ```
    /// section_name: |
    ///   Multi-line content here.
    ///   Indentation is stripped.
    /// ```
    ///
    /// If no YAML keys are found, returns `["": <entire content>]`.
    static func parseSections(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        var sections: [String: String] = [:]
        var currentKey: String?
        var currentLines: [String] = []
        var baseIndent: Int?

        func saveCurrentSection() {
            if let key = currentKey {
                let value = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    sections[key] = value
                }
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comment lines
            if trimmed.hasPrefix("#") { continue }

            // Check for YAML key: `key: |` or `key: |+` or `key: |-`
            if let match = line.range(of: #"^(\w[\w\-]*)\s*:\s*\|[+-]?\s*$"#, options: .regularExpression) {
                saveCurrentSection()
                let keyEnd = line[match].firstIndex(of: ":") ?? match.upperBound
                currentKey = String(line[match.lowerBound..<keyEnd])
                currentLines = []
                baseIndent = nil
            } else if currentKey != nil {
                // Inside a block scalar — collect indented lines
                if trimmed.isEmpty {
                    currentLines.append("")
                } else {
                    let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                    if indent == 0 && !trimmed.isEmpty {
                        // Non-indented non-empty line → check if it's a new key
                        if line.range(of: #"^(\w[\w\-]*)\s*:\s*\|[+-]?\s*$"#, options: .regularExpression) != nil {
                            saveCurrentSection()
                            let keyEnd = line.firstIndex(of: ":") ?? line.endIndex
                            currentKey = String(line[line.startIndex..<keyEnd])
                            currentLines = []
                            baseIndent = nil
                        } else {
                            // Not a key, not indented — end of block
                            saveCurrentSection()
                            currentKey = nil
                            currentLines = []
                            baseIndent = nil
                        }
                    } else {
                        if baseIndent == nil { baseIndent = indent }
                        let stripped = indent >= (baseIndent ?? 0)
                            ? String(line.dropFirst(baseIndent ?? 0))
                            : trimmed
                        currentLines.append(stripped)
                    }
                }
            }
        }

        saveCurrentSection()

        // If no YAML keys found, treat entire content as a single unnamed section
        if sections.isEmpty {
            let content = stripComments(text)
            if !content.isEmpty {
                sections[""] = content
            }
        }

        return sections
    }

    /// Replace `{{key}}` placeholders with values from the provided dictionary.
    static func applyVariables(_ template: String, vars: [String: String]) -> String {
        var result = template
        for (key, value) in vars {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }
}
