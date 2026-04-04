import Foundation

struct GraphNode: Identifiable, Codable {
    let id: String          // relative path
    let title: String
    let folder: String      // top-level folder for coloring
    var connectionCount: Int
}

struct GraphEdge: Codable {
    let source: String      // source node id
    let target: String      // target node id
}

struct VaultGraph: Codable {
    var nodes: [GraphNode]
    var edges: [GraphEdge]

    static var empty: VaultGraph {
        VaultGraph(nodes: [], edges: [])
    }

    func toJSON() -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
