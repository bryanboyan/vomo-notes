import Foundation

struct MarkdownParser {
    /// Result of preprocessing that separates frontmatter from content
    struct ParseResult {
        let frontmatter: String?  // Raw YAML frontmatter (without --- delimiters)
        let content: String       // Processed markdown content
    }

    /// Pre-process and extract frontmatter separately
    static func preprocessWithFrontmatter(_ text: String) -> ParseResult {
        let (frontmatter, body) = extractFrontmatter(text)
        let processed = preprocess(body)
        return ParseResult(frontmatter: frontmatter, content: processed)
    }

    /// Extract YAML frontmatter from the beginning of a markdown file.
    /// Returns (frontmatter content without delimiters, remaining body).
    static func extractFrontmatter(_ text: String) -> (String?, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return (nil, text) }

        // Find the closing --- (must be on its own line)
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, text) }

        var endIndex: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                endIndex = i
                break
            }
        }

        guard let end = endIndex else { return (nil, text) }

        let frontmatter = lines[1..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = lines[(end + 1)...].joined(separator: "\n")

        return (frontmatter.isEmpty ? nil : frontmatter, body)
    }

    /// Pre-process Obsidian-flavored markdown into standard markdown that MarkdownUI can render.
    /// Converts [[wiki links]] and #tags into tappable markdown links.
    static func preprocess(_ text: String) -> String {
        // Strip frontmatter before processing
        let (_, body) = extractFrontmatter(text)
        var result = body

        // Convert [[wiki links]] to markdown links with custom scheme
        // [[Note Name]] → [Note Name](obsidian://open/Note%20Name)
        // [[Note Name|Display Text]] → [Display Text](obsidian://open/Note%20Name)
        let wikiLinkPattern = /\[\[([^\]|]+)(?:\|([^\]]*))?\]\]/
        result = result.replacing(wikiLinkPattern) { match in
            let target = String(match.1).trimmingCharacters(in: .whitespaces)
            let display = match.2.map { String($0).trimmingCharacters(in: .whitespaces) } ?? target
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
            return "[\(display)](obsidian://open/\(encoded))"
        }

        // Convert standalone #tags to tappable links (but not inside code blocks)
        // Uses (^|[^#\w]) prefix to avoid matching ## headings, then restores the prefix char
        result = processOutsideCodeBlocks(result) { line in
            replaceTagsInLine(line)
        }

        // Convert dataview/dataviewjs code blocks to styled placeholders
        result = replaceDataviewBlocks(result)

        return result
    }

    private static func replaceTagsInLine(_ line: String) -> String {
        // Use NSRegularExpression for lookbehind support
        guard let regex = try? NSRegularExpression(pattern: "(?<![#\\w])#([a-zA-Z][a-zA-Z0-9_/-]*)") else {
            return line
        }
        let nsLine = line as NSString
        var result = line
        // Process matches in reverse to preserve indices
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        for match in matches.reversed() {
            guard let tagRange = Range(match.range(at: 1), in: line),
                  let fullRange = Range(match.range, in: line) else { continue }
            let tag = String(line[tagRange])
            let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
            result = result.replacingCharacters(in: fullRange, with: "[#\(tag)](obsidian://tag/\(encoded))")
        }
        return result
    }

    /// Process text line by line, skipping code blocks (``` fenced blocks)
    private static func processOutsideCodeBlocks(_ text: String, transform: (String) -> String) -> String {
        var lines = text.components(separatedBy: "\n")
        var inCodeBlock = false

        for i in lines.indices {
            if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if !inCodeBlock {
                lines[i] = transform(lines[i])
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Replace ```dataview and ```dataviewjs blocks with styled placeholder text
    private static func replaceDataviewBlocks(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let isDataview = trimmed == "```dataview"
            let isDataviewJS = trimmed == "```dataviewjs"
            if isDataview || isDataviewJS {
                let blockType = isDataviewJS ? "DataviewJS" : "Dataview"
                // Find closing ```
                var queryLines: [String] = []
                var j = i + 1
                while j < lines.count {
                    if lines[j].trimmingCharacters(in: .whitespaces) == "```" {
                        break
                    }
                    queryLines.append(lines[j])
                    j += 1
                }
                let query = queryLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                // Replace the block with a blockquote-style placeholder
                let replacement = "> **\(blockType) Query** *(view in Obsidian)*\n>\n> `\(query.replacingOccurrences(of: "\n", with: "` `"))`"
                // Remove old lines and insert replacement
                let endIndex = j < lines.count ? j + 1 : j
                lines.replaceSubrange(i..<endIndex, with: replacement.components(separatedBy: "\n"))
                i += replacement.components(separatedBy: "\n").count
            } else {
                i += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Extract all wiki link targets from markdown text
    static func extractWikiLinks(from text: String) -> [String] {
        let pattern = /\[\[([^\]|]+)(?:\|[^\]]*)?\]\]/
        return text.matches(of: pattern).map { String($0.1).trimmingCharacters(in: .whitespaces) }
    }

    /// Content segment for mixed markdown + dataview rendering
    enum ContentSegment: Identifiable {
        case markdown(String)
        case dataviewQuery(String)
        case dataviewJS(String)
        case inlineQuery(String)          // `= expression` inline DQL

        var id: String {
            switch self {
            case .markdown(let s): return "md:\(s.prefix(40).hashValue)"
            case .dataviewQuery(let q): return "dv:\(q.hashValue)"
            case .dataviewJS(let c): return "js:\(c.hashValue)"
            case .inlineQuery(let e): return "iq:\(e.hashValue)"
            }
        }
    }

    /// Split markdown content into segments, extracting dataview blocks as structured data
    /// instead of replacing them with placeholder text.
    static func extractDataviewBlocks(_ text: String) -> [ContentSegment] {
        // Strip frontmatter first
        let (_, body) = extractFrontmatter(text)
        var segments: [ContentSegment] = []
        let lines = body.components(separatedBy: "\n")
        var i = 0
        var currentMarkdown: [String] = []

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let isDataview = trimmed == "```dataview"
            let isDataviewJS = trimmed == "```dataviewjs"

            if isDataview || isDataviewJS {
                // Flush accumulated markdown
                if !currentMarkdown.isEmpty {
                    let md = currentMarkdown.joined(separator: "\n")
                    if !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        segments.append(.markdown(preprocessBody(md)))
                    }
                    currentMarkdown = []
                }

                // Collect the query/code
                var queryLines: [String] = []
                var j = i + 1
                while j < lines.count {
                    if lines[j].trimmingCharacters(in: .whitespaces) == "```" {
                        break
                    }
                    queryLines.append(lines[j])
                    j += 1
                }
                let query = queryLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

                if isDataview {
                    segments.append(.dataviewQuery(query))
                } else {
                    segments.append(.dataviewJS(query))
                }
                i = j < lines.count ? j + 1 : j
            } else {
                currentMarkdown.append(lines[i])
                i += 1
            }
        }

        // Flush remaining markdown
        if !currentMarkdown.isEmpty {
            let md = currentMarkdown.joined(separator: "\n")
            if !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.markdown(preprocessBody(md)))
            }
        }

        // If no dataview blocks found, return single markdown segment
        if segments.isEmpty {
            let processed = preprocessBody(body)
            if !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.markdown(processed))
            }
        }

        return segments
    }

    /// Process markdown body (wiki links + tags) without frontmatter stripping or dataview replacement
    private static func preprocessBody(_ text: String) -> String {
        var result = text

        // Convert [[wiki links]] to markdown links
        let wikiLinkPattern = /\[\[([^\]|]+)(?:\|([^\]]*))?\]\]/
        result = result.replacing(wikiLinkPattern) { match in
            let target = String(match.1).trimmingCharacters(in: .whitespaces)
            let display = match.2.map { String($0).trimmingCharacters(in: .whitespaces) } ?? target
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
            return "[\(display)](obsidian://open/\(encoded))"
        }

        // Convert standalone #tags to tappable links (outside code blocks)
        result = processOutsideCodeBlocks(result) { line in
            replaceTagsInLine(line)
        }

        return result
    }

    /// Extract all tags from markdown text
    static func extractTags(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(?<![#\\w])#([a-zA-Z][a-zA-Z0-9_/-]*)") else {
            return []
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}

private extension String {
    func replacingCharacters(in range: Range<String.Index>, with replacement: String) -> String {
        var copy = self
        copy.replaceSubrange(range, with: replacement)
        return copy
    }
}
