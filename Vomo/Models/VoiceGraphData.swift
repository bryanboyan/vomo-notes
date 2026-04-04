import Foundation

/// A node in the dynamic voice conversation graph
struct VoiceGraphNode: Identifiable, Codable {
    let id: String              // unique identifier (lowercased entity name)
    let label: String           // display name
    let type: String            // "person", "topic", "place"
    var lastMentioned: Double   // epoch seconds — for fading
    var mentions: Int           // how many times mentioned
}

/// An edge connecting two voice graph nodes
struct VoiceGraphEdge: Codable {
    let source: String
    let target: String
}

/// The full graph state sent to the WebView
struct VoiceGraphData: Codable {
    var nodes: [VoiceGraphNode]
    var edges: [VoiceGraphEdge]

    static var empty: VoiceGraphData {
        VoiceGraphData(nodes: [], edges: [])
    }

    var isEmpty: Bool { nodes.isEmpty }

    func toJSON() -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Manages the evolving voice graph state, handling node addition, edge creation, and fading
@Observable
final class VoiceGraphManager {
    var graphData = VoiceGraphData.empty

    /// Fade threshold: nodes not mentioned within this interval (and not connected to fresh nodes) fade
    private let fadeInterval: TimeInterval = 60

    // MARK: - Entity Ingestion

    /// Add entities extracted by the AI from conversation
    func ingestEntities(_ entities: [ExtractedEntity], connections: [EntityConnection]) {
        let now = Date().timeIntervalSince1970

        for entity in entities {
            let nodeId = entity.name.lowercased()
            if let idx = graphData.nodes.firstIndex(where: { $0.id == nodeId }) {
                graphData.nodes[idx].lastMentioned = now
                graphData.nodes[idx].mentions += 1
            } else {
                let node = VoiceGraphNode(
                    id: nodeId,
                    label: entity.name,
                    type: entity.type,
                    lastMentioned: now,
                    mentions: 1
                )
                graphData.nodes.append(node)
            }
        }

        for conn in connections {
            let srcId = conn.from.lowercased()
            let tgtId = conn.to.lowercased()
            let edgeExists = graphData.edges.contains { e in
                (e.source == srcId && e.target == tgtId) ||
                (e.source == tgtId && e.target == srcId)
            }
            if !edgeExists,
               graphData.nodes.contains(where: { $0.id == srcId }),
               graphData.nodes.contains(where: { $0.id == tgtId }) {
                graphData.edges.append(VoiceGraphEdge(source: srcId, target: tgtId))
            }
        }
    }

    /// Compute opacity for each node based on recency and connections
    func nodeOpacities() -> [String: Double] {
        let now = Date().timeIntervalSince1970
        var freshIds = Set<String>()

        // Mark nodes mentioned within the fade interval as fresh
        for node in graphData.nodes {
            if now - node.lastMentioned < fadeInterval {
                freshIds.insert(node.id)
            }
        }

        // Propagate freshness through edges (1 hop)
        for edge in graphData.edges {
            if freshIds.contains(edge.source) { freshIds.insert(edge.target) }
            if freshIds.contains(edge.target) { freshIds.insert(edge.source) }
        }

        var opacities: [String: Double] = [:]
        for node in graphData.nodes {
            if freshIds.contains(node.id) {
                opacities[node.id] = 1.0
            } else {
                // Fade based on how long ago it was mentioned
                let age = now - node.lastMentioned
                let opacity = max(0.15, 1.0 - (age - fadeInterval) / fadeInterval)
                opacities[node.id] = opacity
            }
        }
        return opacities
    }

    func clear() {
        graphData = .empty
    }
}

/// An entity extracted by the AI from conversation
struct ExtractedEntity: Codable {
    let name: String
    let type: String  // "person", "topic", "place"
}

/// A connection between two extracted entities
struct EntityConnection: Codable {
    let from: String
    let to: String
}
