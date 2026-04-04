import SwiftUI

struct ReaderView: View {
    let file: VaultFile
    @Binding var navigationPath: [VaultFile]
    @Environment(VaultManager.self) var vault
    @Environment(FavoritesManager.self) var favorites
    @Environment(DataviewEngine.self) var dataviewEngine
    @State private var contentSegments: [MarkdownParser.ContentSegment] = []
    @State private var frontmatter: String?
    @State private var showFrontmatter = false
    @State private var showVoiceChat = false
    @State private var showEditor = false
    @Environment(\.agentVoiceActive) private var agentVoiceActive

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let frontmatter {
                    FrontmatterView(yaml: frontmatter, isExpanded: $showFrontmatter)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                ForEach(contentSegments) { segment in
                    switch segment {
                    case .markdown(let text):
                        NativeMarkdownView(text: text)
                            .padding()
                    case .dataviewQuery(let query):
                        DataviewResultView(query: query, engine: dataviewEngine)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                    case .dataviewJS(let code):
                        DataviewJSView(code: code, engine: dataviewEngine)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                    case .inlineQuery(let expr):
                        InlineQueryView(expression: expr, documentPath: file.id, engine: dataviewEngine)
                    }
                }
            }
        }
        .navigationTitle(file.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        showEditor = true
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(Color.obsidianPurple)
                    }

                    Button {
                        showVoiceChat = true
                    } label: {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(agentVoiceActive ? Color.gray : Color.obsidianPurple)
                    }
                    .disabled(agentVoiceActive)

                    Menu {
                        Button {
                            favorites.toggle(file.id)
                        } label: {
                            Label(
                                favorites.isFavorite(file.id) ? "Remove from Favorites" : "Add to Favorites",
                                systemImage: favorites.isFavorite(file.id) ? "star.slash" : "star"
                            )
                        }
                        Button {
                            let activityVC = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
                            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                               let root = windowScene.windows.first?.rootViewController {
                                root.present(activityVC, animated: true)
                            }
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showVoiceChat) {
            VoiceChatOverlay(file: file, isPresented: $showVoiceChat)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showEditor) {
            NoteEditorView(existingFile: file)
                .environment(vault)
        }
        .onChange(of: showEditor) { _, isShowing in
            if !isShowing {
                // Reload content after editing
                let raw = vault.loadContent(for: file)
                let (fm, _) = MarkdownParser.extractFrontmatter(raw)
                frontmatter = fm
                contentSegments = MarkdownParser.extractDataviewBlocks(raw)
            }
        }
        .task {
            let loader = vault
            let targetFile = file
            let (fm, segments) = await Task.detached(priority: .userInitiated) {
                let raw = loader.loadContent(for: targetFile)
                let (fm, _) = MarkdownParser.extractFrontmatter(raw)
                let segs = MarkdownParser.extractDataviewBlocks(raw)
                return (fm, segs)
            }.value
            frontmatter = fm
            contentSegments = segments
        }
    }
}

// MARK: - Frontmatter Collapsible View

struct FrontmatterView: View {
    let yaml: String
    @Binding var isExpanded: Bool

    private var properties: [FrontmatterProperty] {
        FrontmatterProperty.parse(yaml)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Properties")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(properties.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(properties) { prop in
                        PropertyRowView(property: prop)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Frontmatter Data Model

struct FrontmatterProperty: Identifiable {
    let id: String // key
    let key: String
    let value: FrontmatterValue

    enum FrontmatterValue {
        case string(String)
        case number(String)
        case bool(Bool)
        case date(String)
        case tags([String])
        case list([String])
        case link(String) // [[wiki link]]
    }

    static func parse(_ yaml: String) -> [FrontmatterProperty] {
        var result: [FrontmatterProperty] = []
        let lines = yaml.components(separatedBy: "\n")
        var currentKey: String?
        var currentListItems: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // List item continuation (indented with -)
            if trimmed.hasPrefix("- "), currentKey != nil {
                let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                currentListItems.append(item)
                continue
            }

            // Flush previous list if we had one
            if let key = currentKey, !currentListItems.isEmpty {
                let value = classifyList(currentListItems, forKey: key)
                result.append(FrontmatterProperty(id: key, key: key, value: value))
                currentKey = nil
                currentListItems = []
            }

            // Parse key: value
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

            guard !key.isEmpty else { continue }

            if rawValue.isEmpty {
                // Might be start of a list
                currentKey = key
                currentListItems = []
                continue
            }

            // Inline array: [item1, item2] but NOT [[wiki links]]
            if rawValue.hasPrefix("[") && rawValue.hasSuffix("]") && !rawValue.hasPrefix("[[") {
                let inner = String(rawValue.dropFirst().dropLast())
                let items = inner.components(separatedBy: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }.filter { !$0.isEmpty }
                let value = classifyList(items, forKey: key)
                result.append(FrontmatterProperty(id: key, key: key, value: value))
                continue
            }

            // Classify single value
            result.append(FrontmatterProperty(id: key, key: key, value: classifyValue(rawValue, forKey: key)))
        }

        // Flush trailing list
        if let key = currentKey, !currentListItems.isEmpty {
            let value = classifyList(currentListItems, forKey: key)
            result.append(FrontmatterProperty(id: key, key: key, value: value))
        }

        return result
    }

    private static func classifyValue(_ raw: String, forKey key: String) -> FrontmatterValue {
        let stripped = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        // Wiki link
        if stripped.hasPrefix("[[") && stripped.hasSuffix("]]") {
            let linkName = String(stripped.dropFirst(2).dropLast(2))
            return .link(linkName)
        }

        // Boolean
        if stripped.lowercased() == "true" || stripped.lowercased() == "false" {
            return .bool(stripped.lowercased() == "true")
        }

        // Date (YYYY-MM-DD pattern)
        if stripped.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
            return .date(stripped)
        }

        // Number
        if Double(stripped) != nil {
            return .number(stripped)
        }

        // Tag-like keys
        if key.lowercased() == "tags" || key.lowercased() == "tag" {
            return .tags([stripped])
        }

        return .string(stripped)
    }

    private static func classifyList(_ items: [String], forKey key: String) -> FrontmatterValue {
        let cleaned = items.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        if key.lowercased() == "tags" || key.lowercased() == "tag" || key.lowercased() == "cssclasses" {
            return .tags(cleaned)
        }
        if key.lowercased() == "aliases" || key.lowercased() == "alias" {
            return .list(cleaned)
        }
        // Check if items look like tags (no spaces, short)
        if cleaned.allSatisfy({ !$0.contains(" ") && $0.count < 30 }) && cleaned.count <= 10 {
            return .tags(cleaned)
        }
        return .list(cleaned)
    }
}

// MARK: - Property Row View

struct PropertyRowView: View {
    let property: FrontmatterProperty

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(property.key)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)
                .lineLimit(1)

            propertyValue
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var propertyValue: some View {
        switch property.value {
        case .string(let s):
            Text(s)
                .font(.caption)
                .foregroundStyle(.secondary)

        case .number(let n):
            Text(n)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

        case .bool(let b):
            HStack(spacing: 4) {
                Image(systemName: b ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(b ? .green : .red)
                Text(b ? "true" : "false")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .date(let d):
            Text(d)
                .font(.caption)
                .foregroundStyle(.secondary)

        case .tags(let tags):
            FlowLayout(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.obsidianPurple.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.obsidianPurple)
                }
            }

        case .list(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .link(let name):
            Text(name)
                .font(.caption)
                .foregroundStyle(Color.obsidianPurple)
        }
    }
}

// MARK: - Flow Layout for Tags

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

