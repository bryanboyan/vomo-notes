import Foundation

/// Lightweight metadata extracted from frontmatter for display in listing rows.
struct FileMetadata {
    let date: String?           // frontmatter "date" property (YYYY-MM-DD)
    let endDate: String?        // optional "end_date" / "endDate" for ranges
    let mood: String?           // frontmatter "mood" property
    let tags: [String]          // frontmatter + inline tags (first few)

    var dateDisplay: String? {
        guard let date else { return nil }
        if let endDate, endDate != date {
            return formatDate(date) + " \u{2013} " + formatDate(endDate)
        }
        return formatDate(date)
    }

    var isEmpty: Bool {
        date == nil && mood == nil && tags.isEmpty
    }

    private func formatDate(_ iso: String) -> String {
        // Parse YYYY-MM-DD and format as "Mar 24"
        let parts = iso.split(separator: "-")
        guard parts.count >= 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return iso }
        let months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        guard month >= 1 && month <= 12 else { return iso }
        return "\(months[month - 1]) \(day)"
    }
}
