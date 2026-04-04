import Foundation

/// Extracts metadata from markdown files and stores it in the Dataview database.
struct MetadataIndexer {

    /// Index a single vault file into the database
    static func indexFile(_ file: VaultFile, content: String, db: DataviewDatabase, resolveLink: ((String) -> String?)? = nil) throws {
        let (frontmatterYAML, body) = MarkdownParser.extractFrontmatter(content)

        // Document record
        let doc = DocumentRecord(
            path: file.id,
            title: file.title,
            folderPath: file.folderPath,
            modifiedDate: file.modifiedDate.timeIntervalSince1970,
            fileSize: content.utf8.count
        )

        // Parse frontmatter properties
        var properties: [PropertyRecord] = []
        var propertyValues: [PropertyValueRecord] = []
        var aliases: [AliasRecord] = []

        if let yaml = frontmatterYAML {
            let parsed = FrontmatterProperty.parse(yaml)
            for prop in parsed {
                switch prop.value {
                case .string(let s):
                    properties.append(PropertyRecord(
                        documentPath: file.id, key: prop.key,
                        valueText: s, valueNumber: nil, valueDate: nil,
                        source: "frontmatter"
                    ))
                case .number(let n):
                    properties.append(PropertyRecord(
                        documentPath: file.id, key: prop.key,
                        valueText: n, valueNumber: Double(n), valueDate: nil,
                        source: "frontmatter"
                    ))
                case .bool(let b):
                    properties.append(PropertyRecord(
                        documentPath: file.id, key: prop.key,
                        valueText: b ? "true" : "false", valueNumber: b ? 1 : 0, valueDate: nil,
                        source: "frontmatter"
                    ))
                case .date(let d):
                    properties.append(PropertyRecord(
                        documentPath: file.id, key: prop.key,
                        valueText: d, valueNumber: nil, valueDate: d,
                        source: "frontmatter"
                    ))
                case .link(let name):
                    properties.append(PropertyRecord(
                        documentPath: file.id, key: prop.key,
                        valueText: "[[" + name + "]]", valueNumber: nil, valueDate: nil,
                        source: "frontmatter"
                    ))
                case .tags(let items):
                    // Store as property with first value
                    properties.append(PropertyRecord(
                        documentPath: file.id, key: prop.key,
                        valueText: items.joined(separator: ", "), valueNumber: nil, valueDate: nil,
                        source: "frontmatter"
                    ))
                    // Store individual values
                    for (i, item) in items.enumerated() {
                        propertyValues.append(PropertyValueRecord(
                            documentPath: file.id, key: prop.key,
                            valueText: item, sortOrder: i
                        ))
                    }
                case .list(let items):
                    properties.append(PropertyRecord(
                        documentPath: file.id, key: prop.key,
                        valueText: items.joined(separator: ", "), valueNumber: nil, valueDate: nil,
                        source: "frontmatter"
                    ))
                    for (i, item) in items.enumerated() {
                        propertyValues.append(PropertyValueRecord(
                            documentPath: file.id, key: prop.key,
                            valueText: item, sortOrder: i
                        ))
                    }
                }

                // Track aliases
                if prop.key.lowercased() == "aliases" || prop.key.lowercased() == "alias" {
                    switch prop.value {
                    case .list(let items), .tags(let items):
                        for item in items {
                            aliases.append(AliasRecord(documentPath: file.id, alias: item))
                        }
                    case .string(let s):
                        aliases.append(AliasRecord(documentPath: file.id, alias: s))
                    default: break
                    }
                }
            }
        }

        // Extract tags from body
        let bodyTags = MarkdownParser.extractTags(from: body)
        var tagRecords: [TagRecord] = bodyTags.map { TagRecord(documentPath: file.id, tag: $0) }

        // Also include frontmatter tags
        if let yaml = frontmatterYAML {
            let parsed = FrontmatterProperty.parse(yaml)
            for prop in parsed where prop.key.lowercased() == "tags" || prop.key.lowercased() == "tag" {
                switch prop.value {
                case .tags(let items):
                    for item in items {
                        tagRecords.append(TagRecord(documentPath: file.id, tag: item))
                    }
                case .string(let s):
                    tagRecords.append(TagRecord(documentPath: file.id, tag: s))
                default: break
                }
            }
        }

        // Extract wiki links
        let wikiLinks = MarkdownParser.extractWikiLinks(from: content)
        let linkRecords: [LinkRecord] = wikiLinks.map { linkTarget in
            // Strip heading anchor for resolution
            var cleanTarget = linkTarget
            if let hashIndex = cleanTarget.firstIndex(of: "#") {
                cleanTarget = String(cleanTarget[cleanTarget.startIndex..<hashIndex])
            }
            let resolved = resolveLink?(cleanTarget)
            return LinkRecord(
                sourcePath: file.id,
                targetPath: linkTarget,
                targetResolved: resolved,
                displayText: nil
            )
        }

        // Extract inline fields (key:: value) from body
        let inlineFields = extractInlineFields(from: body)
        for field in inlineFields {
            // Don't overwrite frontmatter properties
            if !properties.contains(where: { $0.key == field.key }) {
                properties.append(PropertyRecord(
                    documentPath: file.id, key: field.key,
                    valueText: field.valueText, valueNumber: field.valueNumber,
                    valueDate: field.valueDate, source: "inline"
                ))
            }
        }

        // Extract tasks
        let taskRecords = extractTasks(from: body, documentPath: file.id)

        // Write everything in one transaction
        try db.indexDocument(
            doc,
            properties: properties,
            propertyValues: propertyValues,
            tags: tagRecords,
            links: linkRecords,
            tasks: taskRecords,
            aliases: aliases
        )

        // Index full-text search
        try db.indexNoteContent(
            path: file.id,
            title: file.title,
            body: body,
            tags: tagRecords.map(\.tag)
        )
    }

    /// Extract markdown tasks (- [ ] and - [x]) from body text
    static func extractTasks(from text: String, documentPath: String) -> [TaskRecord] {
        var tasks: [TaskRecord] = []
        let lines = text.components(separatedBy: "\n")

        for (lineNum, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [ ] ") {
                let taskText = String(trimmed.dropFirst(6))
                tasks.append(TaskRecord(
                    id: nil, documentPath: documentPath,
                    text: taskText, completed: false, lineNumber: lineNum + 1
                ))
            } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                let taskText = String(trimmed.dropFirst(6))
                tasks.append(TaskRecord(
                    id: nil, documentPath: documentPath,
                    text: taskText, completed: true, lineNumber: lineNum + 1
                ))
            }
        }

        return tasks
    }

    /// Extract inline fields from markdown body text.
    /// Supports three formats:
    /// - Full-line: `key:: value`
    /// - Bracket inline: `[key:: value]`
    /// - Paren inline: `(key:: value)`
    static func extractInlineFields(from text: String) -> [PropertyRecord] {
        var fields: [PropertyRecord] = []
        var seen = Set<String>()
        let lines = text.components(separatedBy: "\n")

        // Skip lines inside code blocks
        var inCodeBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock { continue }

            // Match all inline field patterns in this line
            extractInlineFieldsFromLine(trimmed, into: &fields, seen: &seen)
        }

        return fields
    }

    private static func extractInlineFieldsFromLine(_ line: String, into fields: inout [PropertyRecord], seen: inout Set<String>) {
        // Pattern 1: Full-line field: `key:: value` (key at start of line)
        if let match = line.range(of: #"^([a-zA-Z][a-zA-Z0-9_-]*)::[ \t]+(.+)$"#, options: .regularExpression) {
            let fullMatch = String(line[match])
            if let colonRange = fullMatch.range(of: "::") {
                let key = String(fullMatch[fullMatch.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let value = String(fullMatch[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty && !value.isEmpty && !seen.contains(key) {
                    seen.insert(key)
                    fields.append(classifyInlineField(key: key, value: value))
                }
            }
            return
        }

        // Pattern 2 & 3: Bracket/paren inline fields: `[key:: value]` or `(key:: value)`
        // Can appear multiple times per line
        let patterns = [
            #"\[([a-zA-Z][a-zA-Z0-9_-]*)::[ \t]+([^\]]+)\]"#,
            #"\(([a-zA-Z][a-zA-Z0-9_-]*)::[ \t]+([^)]+)\)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsLine = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            for m in matches {
                guard m.numberOfRanges >= 3,
                      let keyRange = Range(m.range(at: 1), in: line),
                      let valRange = Range(m.range(at: 2), in: line) else { continue }
                let key = String(line[keyRange])
                let value = String(line[valRange]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty && !value.isEmpty && !seen.contains(key) {
                    seen.insert(key)
                    fields.append(classifyInlineField(key: key, value: value))
                }
            }
        }
    }

    private static func classifyInlineField(key: String, value: String) -> PropertyRecord {
        // Try number
        if let n = Double(value) {
            return PropertyRecord(
                documentPath: "", key: key,
                valueText: value, valueNumber: n, valueDate: nil,
                source: "inline"
            )
        }

        // Try date (YYYY-MM-DD)
        if value.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
            return PropertyRecord(
                documentPath: "", key: key,
                valueText: value, valueNumber: nil, valueDate: value,
                source: "inline"
            )
        }

        // Try boolean
        if value.lowercased() == "true" || value.lowercased() == "false" {
            let b = value.lowercased() == "true"
            return PropertyRecord(
                documentPath: "", key: key,
                valueText: value, valueNumber: b ? 1 : 0, valueDate: nil,
                source: "inline"
            )
        }

        // Default: string
        return PropertyRecord(
            documentPath: "", key: key,
            valueText: value, valueNumber: nil, valueDate: nil,
            source: "inline"
        )
    }
}
