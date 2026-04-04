import SwiftUI

/// Card component for files found by the voice search agent
struct AgentFileCard: View {
    let foundFile: FoundFile
    var metadata: FileMetadata?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon with optional search badge
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "doc.text")
                        .font(.title3)
                        .foregroundStyle(Color.obsidianPurple)
                        .frame(width: 36, height: 36)
                        .background(Color.obsidianPurple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                    if foundFile.isHighlighted {
                        Image(systemName: "magnifyingglass.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.obsidianPurple)
                            .offset(x: 4, y: 4)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(foundFile.file.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let metadata, !metadata.isEmpty {
                        MetadataChipsView(metadata: metadata)
                    }

                    if !foundFile.snippet.isEmpty {
                        Text(foundFile.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if !foundFile.file.contentSnippet.isEmpty {
                        Text(foundFile.file.contentSnippet)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }

                    if !foundFile.reason.isEmpty {
                        Text(foundFile.reason)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                foundFile.isHighlighted
                    ? Color.obsidianPurple.opacity(0.05)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
    }
}
