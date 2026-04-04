import SwiftUI

// MARK: - SearchResultRow

struct SearchResultRow: View {
    let file: VaultFile
    let highlightText: String?
    var metadata: FileMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(Color.obsidianPurple)
                    .font(.subheadline)
                Text(file.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }

            HStack(spacing: 4) {
                if !file.folderPath.isEmpty {
                    Text(file.folderPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\u{00B7}")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "plus.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(file.createdDate.shortFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\u{00B7}")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Image(systemName: "pencil.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(file.modifiedDate.relativeFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let metadata, !metadata.isEmpty {
                MetadataChipsView(metadata: metadata)
            }

            if !file.contentSnippet.isEmpty {
                Text(snippetText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var snippetText: String {
        guard let highlight = highlightText, !highlight.isEmpty,
              let range = file.contentSnippet.range(of: highlight, options: .caseInsensitive) else {
            return file.contentSnippet
        }

        // Show context around the match
        let matchStart = file.contentSnippet.distance(from: file.contentSnippet.startIndex, to: range.lowerBound)
        let start = max(0, matchStart - 40)
        let startIndex = file.contentSnippet.index(file.contentSnippet.startIndex, offsetBy: start)
        let prefix = start > 0 ? "..." : ""
        return prefix + String(file.contentSnippet[startIndex...]).prefix(150)
    }
}

extension Date {
    var relativeFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    var shortFormatted: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDate(self, equalTo: Date(), toGranularity: .year) {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: self)
    }
}
