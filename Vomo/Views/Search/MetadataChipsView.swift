import SwiftUI

/// Displays compact metadata chips (date, mood, tags) for a listing row.
struct MetadataChipsView: View {
    let metadata: FileMetadata

    var body: some View {
        HStack(spacing: 6) {
            if let dateDisplay = metadata.dateDisplay {
                chip(dateDisplay, icon: "calendar", color: .blue)
            }
            if let mood = metadata.mood {
                chip(mood, icon: "face.smiling", color: .orange)
            }
            ForEach(metadata.tags, id: \.self) { tag in
                chip("#\(tag)", icon: nil, color: .obsidianPurple)
            }
        }
    }

    private func chip(_ text: String, icon: String?, color: Color) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
            }
            Text(text)
                .font(.caption2)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.1), in: Capsule())
    }
}
