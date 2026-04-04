import SwiftUI

/// Editable property for frontmatter.
struct EditableProperty: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
}

/// Inline property editor for note frontmatter. Add, edit, and remove properties.
struct PropertyEditorView: View {
    @Binding var properties: [EditableProperty]
    @State private var isExpanded = true
    @State private var newKey = ""
    @State private var newValue = ""
    @FocusState private var focusedField: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
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
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !properties.isEmpty {
                        Text("\(properties.count)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    // Existing properties
                    ForEach($properties) { $prop in
                        HStack(spacing: 6) {
                            TextField("key", text: $prop.key)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.obsidianPurple)
                                .frame(width: 80, alignment: .trailing)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            Text(":")
                                .font(.caption)
                                .foregroundStyle(.tertiary)

                            TextField("value", text: $prop.value)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textInputAutocapitalization(.never)
                                .focused($focusedField, equals: prop.id)

                            Button {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    properties.removeAll { $0.id == prop.id }
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)

                        if prop.id != properties.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }

                    // Add new property row
                    HStack(spacing: 6) {
                        TextField("new key", text: $newKey)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.obsidianPurple)
                            .frame(width: 80, alignment: .trailing)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { addProperty() }

                        Text(":")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        TextField("value", text: $newValue)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textInputAutocapitalization(.never)
                            .onSubmit { addProperty() }

                        Button {
                            addProperty()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.caption)
                                .foregroundStyle(canAdd ? Color.obsidianPurple : Color.gray.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canAdd)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)

                    // Quick-add buttons for common properties
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            quickAddChip("date", value: todayString)
                            quickAddChip("tags", value: "")
                            quickAddChip("type", value: "")
                            quickAddChip("status", value: "draft")
                            quickAddChip("project", value: "")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    private var canAdd: Bool {
        let trimmedKey = newKey.trimmingCharacters(in: .whitespaces)
        return !trimmedKey.isEmpty
    }

    private var todayString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    private func addProperty() {
        let trimmedKey = newKey.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty else { return }
        let prop = EditableProperty(key: trimmedKey, value: newValue.trimmingCharacters(in: .whitespaces))
        withAnimation(.easeOut(duration: 0.15)) {
            properties.append(prop)
        }
        newKey = ""
        newValue = ""
        focusedField = prop.id
    }

    private func quickAddChip(_ key: String, value: String) -> some View {
        let exists = properties.contains { $0.key.lowercased() == key.lowercased() }
        return Button {
            guard !exists else { return }
            let prop = EditableProperty(key: key, value: value)
            withAnimation(.easeOut(duration: 0.15)) {
                properties.append(prop)
            }
            if value.isEmpty {
                focusedField = prop.id
            }
        } label: {
            Text(key)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    exists ? Color.gray.opacity(0.1) : Color.obsidianPurple.opacity(0.1),
                    in: Capsule()
                )
                .foregroundStyle(exists ? Color.gray : Color.obsidianPurple)
        }
        .buttonStyle(.plain)
        .disabled(exists)
    }
}

// MARK: - Frontmatter Serialization

extension Array where Element == EditableProperty {
    /// Serialize properties to YAML frontmatter block.
    func toFrontmatter() -> String {
        guard !isEmpty else { return "" }
        var lines = ["---"]
        for prop in self {
            let key = prop.key.trimmingCharacters(in: .whitespaces)
            let value = prop.value.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            // Handle multi-value (comma-separated → YAML list)
            if key.lowercased() == "tags" || key.lowercased() == "aliases" {
                let items = value.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if items.count > 1 {
                    lines.append("\(key):")
                    for item in items {
                        lines.append("  - \(item)")
                    }
                    continue
                }
            }

            // Wrap strings that need quoting
            if value.contains(":") || value.contains("#") {
                lines.append("\(key): \"\(value)\"")
            } else {
                lines.append("\(key): \(value)")
            }
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// Parse YAML frontmatter string into editable properties.
    static func fromFrontmatter(_ yaml: String) -> [EditableProperty] {
        var result: [EditableProperty] = []
        let lines = yaml.components(separatedBy: "\n")
        var currentKey: String?
        var listItems: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // List continuation
            if trimmed.hasPrefix("- "), currentKey != nil {
                listItems.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                continue
            }

            // Flush previous list
            if let key = currentKey, !listItems.isEmpty {
                result.append(EditableProperty(key: key, value: listItems.joined(separator: ", ")))
                currentKey = nil
                listItems = []
            }

            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            guard !key.isEmpty else { continue }

            if rawValue.isEmpty {
                currentKey = key
                listItems = []
                continue
            }

            // Strip inline array brackets
            if rawValue.hasPrefix("[") && rawValue.hasSuffix("]") && !rawValue.hasPrefix("[[") {
                let inner = String(rawValue.dropFirst().dropLast())
                let items = inner.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                    .filter { !$0.isEmpty }
                result.append(EditableProperty(key: key, value: items.joined(separator: ", ")))
                continue
            }

            // Strip surrounding quotes
            let cleaned = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            result.append(EditableProperty(key: key, value: cleaned))
        }

        // Flush trailing list
        if let key = currentKey, !listItems.isEmpty {
            result.append(EditableProperty(key: key, value: listItems.joined(separator: ", ")))
        }

        return result
    }
}
