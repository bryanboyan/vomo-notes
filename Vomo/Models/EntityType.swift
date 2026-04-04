import Foundation

enum EntityType: String, Codable, CaseIterable {
    case person
    case place
    case thing

    var label: String {
        switch self {
        case .person: "People"
        case .place: "Places"
        case .thing: "Things"
        }
    }

    var color: String {
        switch self {
        case .person: "#be4bdb"
        case .place: "#339af0"
        case .thing: "#51cf66"
        }
    }

    /// Classify a vault file into an entity type.
    /// Priority: frontmatter `type:` field > folder convention > default (thing)
    static func classify(folderPath: String, frontmatter: String?) -> EntityType {
        // 1. Check frontmatter type field
        if let fm = frontmatter {
            let lines = fm.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("type:") {
                    let value = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased()
                    switch value {
                    case "person", "people", "contact": return .person
                    case "place", "location": return .place
                    case "thing": return .thing
                    default: break
                    }
                }
            }
        }

        // 2. Check folder convention
        let topFolder = folderPath.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        switch topFolder {
        case "people", "contacts", "person": return .person
        case "places", "locations", "place": return .place
        default: break
        }

        // 3. Default
        return .thing
    }
}
