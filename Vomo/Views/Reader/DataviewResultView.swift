import SwiftUI

/// Renders a Dataview query result inline in a note
struct DataviewResultView: View {
    let query: String
    let engine: DataviewEngine
    var preloadedResult: DataviewResult?

    @State private var result: DataviewResult?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let result {
                switch result.queryType {
                case .table:
                    tableView(result)
                case .list:
                    listView(result)
                case .task:
                    taskView(result)
                case .calendar:
                    placeholderView("Calendar view not yet supported")
                }
            } else if let error {
                errorView(error)
            } else if engine.isIndexing {
                ProgressView("Indexing vault...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                placeholderView("No results")
            }
        }
        .task {
            if let preloaded = preloadedResult {
                result = preloaded
            } else {
                executeQuery()
            }
        }
    }

    private func executeQuery() {
        if let r = engine.executeQuery(query) {
            result = r
        } else {
            error = "Could not execute query"
        }
    }

    // MARK: - TABLE rendering

    @ViewBuilder
    private func tableView(_ result: DataviewResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(result.columns, id: \.self) { col in
                    Text(col)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                }
            }
            .background(Color.cardBackground)

            Divider()

            // Data rows
            ForEach(result.rows) { row in
                HStack(spacing: 0) {
                    // File column (unless WITHOUT ID)
                    if result.columns.first == "File" {
                        Text(row.title)
                            .font(.caption)
                            .foregroundStyle(Color.obsidianPurple)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                    }

                    // Value columns
                    ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                        dataviewValueView(value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                    }
                }

                Divider().opacity(0.5)
            }
        }
        .background(Color.cardBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }

    // MARK: - LIST rendering

    @ViewBuilder
    private func listView(_ result: DataviewResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(result.rows) { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.obsidianPurple.opacity(0.6))
                        .frame(width: 5, height: 5)
                    Text(row.title)
                        .font(.callout)
                        .foregroundStyle(Color.obsidianPurple)
                    if let value = row.values.first {
                        Text("- \(value.displayString)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - TASK rendering

    @ViewBuilder
    private func taskView(_ result: DataviewResult) -> some View {
        let grouped = Dictionary(grouping: result.rows, by: { $0.title })
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(grouped.keys.sorted()), id: \.self) { title in
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.obsidianPurple)

                    ForEach(grouped[title] ?? []) { row in
                        let text = row.values.first?.displayString ?? ""
                        let completed = row.values.count > 1 && row.values[1].displayString == "true"
                        HStack(spacing: 6) {
                            Image(systemName: completed ? "checkmark.square" : "square")
                                .font(.caption)
                                .foregroundStyle(completed ? .green : .secondary)
                            Text(text)
                                .font(.caption)
                                .foregroundStyle(completed ? .secondary : .primary)
                                .strikethrough(completed)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Value rendering

    @ViewBuilder
    private func dataviewValueView(_ value: DataviewValue) -> some View {
        switch value {
        case .text(let s):
            Text(s)
                .font(.caption)
                .foregroundStyle(.primary)
        case .number:
            Text(value.displayString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
        case .date(let d):
            Text(d)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .bool(let b):
            Image(systemName: b ? "checkmark.circle.fill" : "xmark.circle")
                .font(.caption)
                .foregroundStyle(b ? .green : .red)
        case .link(_, let display):
            Text(display)
                .font(.caption)
                .foregroundStyle(Color.obsidianPurple)
        case .list(let items):
            Text(items.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.primary)
        case .null:
            Text("-")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Placeholder / Error

    @ViewBuilder
    private func placeholderView(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Renders DataviewJS blocks — tries to translate to DQL first, falls back to placeholder
struct DataviewJSView: View {
    let code: String
    let engine: DataviewEngine

    @State private var result: DataviewResult?
    @State private var translated = false

    var body: some View {
        if translated, let result {
            DataviewResultView(query: "", engine: engine, preloadedResult: result)
        } else {
            // Show placeholder with code preview
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "curlybraces")
                        .foregroundStyle(.tertiary)
                    Text("DataviewJS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !translated {
                        Text("Not translatable")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(code)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .task {
                if let r = engine.executeDataviewJS(code) {
                    result = r
                    translated = true
                }
            }
        }
    }
}

/// Renders inline DQL expressions (`= this.field`)
struct InlineQueryView: View {
    let expression: String
    let documentPath: String
    let engine: DataviewEngine

    @State private var value: String?

    var body: some View {
        if let value {
            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(.horizontal)
        }
    }

    init(expression: String, documentPath: String, engine: DataviewEngine) {
        self.expression = expression
        self.documentPath = documentPath
        self.engine = engine
        _value = State(initialValue: engine.evaluateInlineExpression(expression, forDocument: documentPath))
    }
}

/// Placeholder for DataviewJS blocks (not supported) — kept for backward compatibility
struct DataviewPlaceholderView: View {
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces")
                    .foregroundStyle(.tertiary)
                Text("DataviewJS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Not supported")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(code)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
