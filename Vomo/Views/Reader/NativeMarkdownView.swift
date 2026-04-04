import SwiftUI

/// Renders markdown text using native SwiftUI — no third-party dependencies.
struct NativeMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            headingView(level: level, content: content)
                .padding(.bottom, level == 1 ? 8 : level == 2 ? 6 : 4)
                .padding(.top, 4)

        case .codeBlock(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(12)
            }
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 8))
            .padding(.vertical, 8)

        case .blockquote(let content):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.obsidianPurple.opacity(0.5))
                    .frame(width: 4)
                inlineMarkdownView(content)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
            .padding(.vertical, 8)

        case .paragraph(let content):
            inlineMarkdownView(content)
                .padding(.vertical, 4)

        case .listItem(let content, let ordered, let index):
            HStack(alignment: .top, spacing: 6) {
                if ordered {
                    Text("\(index).")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                } else {
                    Text("•")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }
                inlineMarkdownView(content)
            }
            .padding(.vertical, 2)

        case .horizontalRule:
            Divider()
                .padding(.vertical, 12)

        case .empty:
            Spacer().frame(height: 8)
        }
    }

    private func headingView(level: Int, content: String) -> some View {
        let size: CGFloat = level == 1 ? 28 : level == 2 ? 24 : 20
        let weight: Font.Weight = level <= 2 ? .bold : .semibold
        return inlineMarkdownView(content)
            .font(.system(size: size, weight: weight))
    }

    @ViewBuilder
    private func inlineMarkdownView(_ text: String) -> some View {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
                .font(.system(size: 16))
                .tint(Color.obsidianPurple)
        } else {
            Text(text)
                .font(.system(size: 16))
        }
    }

    // MARK: - Block Parser

    private enum MarkdownBlock {
        case heading(level: Int, content: String)
        case codeBlock(String)
        case blockquote(String)
        case paragraph(String)
        case listItem(content: String, ordered: Bool, index: Int)
        case horizontalRule
        case empty
    }

    private func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty line
            if trimmed.isEmpty {
                blocks.append(.empty)
                i += 1
                continue
            }

            // Fenced code block
            if trimmed.hasPrefix("```") {
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                i += 1 // skip closing ```
                continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" })
                let level = min(hashes.count, 6)
                let content = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, content: content))
                i += 1
                continue
            }

            // Horizontal rule
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == " " }) &&
                trimmed.filter({ $0 != " " }).count >= 3 &&
                Set(trimmed.filter({ $0 != " " })).count == 1 {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var quoteLines: [String] = []
                while i < lines.count {
                    let ql = lines[i].trimmingCharacters(in: .whitespaces)
                    if ql.hasPrefix("> ") {
                        quoteLines.append(String(ql.dropFirst(2)))
                    } else if ql == ">" {
                        quoteLines.append("")
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            // Unordered list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let content = String(trimmed.dropFirst(2))
                blocks.append(.listItem(content: content, ordered: false, index: 0))
                i += 1
                continue
            }

            // Checkbox list
            if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                let content = String(trimmed.dropFirst(6))
                let checked = trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]")
                let prefix = checked ? "☑ " : "☐ "
                blocks.append(.listItem(content: prefix + content, ordered: false, index: 0))
                i += 1
                continue
            }

            // Ordered list
            if let match = trimmed.range(of: #"^(\d+)\.\s+"#, options: .regularExpression) {
                let numStr = trimmed[trimmed.startIndex..<trimmed.index(before: match.upperBound)]
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ".", with: "")
                let num = Int(numStr) ?? 1
                let content = String(trimmed[match.upperBound...])
                blocks.append(.listItem(content: content, ordered: true, index: num))
                i += 1
                continue
            }

            // Regular paragraph — collect consecutive non-empty, non-special lines
            var paraLines: [String] = []
            while i < lines.count {
                let pl = lines[i].trimmingCharacters(in: .whitespaces)
                if pl.isEmpty || pl.hasPrefix("#") || pl.hasPrefix("```") ||
                   pl.hasPrefix("> ") || pl.hasPrefix("- ") || pl.hasPrefix("* ") ||
                   pl.hasPrefix("+ ") || pl.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil {
                    break
                }
                paraLines.append(lines[i])
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(paraLines.joined(separator: "\n")))
            }
        }

        return blocks
    }
}
