import Testing
import Foundation
@testable import Vomo

@Suite("Graph Building")
struct GraphBuildingTests {

    private func makeFile(id: String, title: String, content: String?) -> VaultFile {
        VaultFile(
            id: id,
            url: URL(fileURLWithPath: "/vault/\(id)"),
            title: title,
            relativePath: id,
            folderPath: "",
            createdDate: Date(),
            modifiedDate: Date(),
            contentSnippet: "",
            content: content
        )
    }

    @Test("Simple bidirectional link creates nodes and edge")
    func simpleLinkCreatesEdge() {
        let files = [
            makeFile(id: "a.md", title: "A", content: "Link to [[B]]"),
            makeFile(id: "b.md", title: "B", content: "Link to [[A]]"),
        ]
        let vm = VaultManager()
        let graph = vm.testBuildGraph(from: files)
        #expect(graph.nodes.count == 2)
        #expect(graph.edges.count == 2)
    }

    @Test("Aliased link resolves correctly")
    func aliasedLink() {
        let files = [
            makeFile(id: "note.md", title: "Note", content: "See [[Target|Display Name]]"),
            makeFile(id: "target.md", title: "Target", content: "Content"),
        ]
        let vm = VaultManager()
        let graph = vm.testBuildGraph(from: files)
        #expect(graph.edges.count == 1)
        #expect(graph.edges[0].source == "note.md")
        #expect(graph.edges[0].target == "target.md")
    }

    @Test("Unresolved link creates no edge")
    func unresolvedLink() {
        let files = [
            makeFile(id: "a.md", title: "A", content: "Link to [[Nonexistent]]"),
        ]
        let vm = VaultManager()
        let graph = vm.testBuildGraph(from: files)
        #expect(graph.nodes.isEmpty)
        #expect(graph.edges.isEmpty)
    }

    @Test("File without content produces no edges")
    func noContent() {
        let files = [
            makeFile(id: "a.md", title: "A", content: nil),
            makeFile(id: "b.md", title: "B", content: nil),
        ]
        let vm = VaultManager()
        let graph = vm.testBuildGraph(from: files)
        #expect(graph.nodes.isEmpty)
        #expect(graph.edges.isEmpty)
    }

    @Test("Connection count is correct")
    func connectionCount() {
        let files = [
            makeFile(id: "hub.md", title: "Hub", content: "Links: [[A]] [[B]] [[C]]"),
            makeFile(id: "a.md", title: "A", content: ""),
            makeFile(id: "b.md", title: "B", content: ""),
            makeFile(id: "c.md", title: "C", content: ""),
        ]
        let vm = VaultManager()
        let graph = vm.testBuildGraph(from: files)
        let hub = graph.nodes.first(where: { $0.id == "hub.md" })
        #expect(hub != nil)
        #expect(hub!.connectionCount == 3) // 3 outgoing
    }

    @Test("Multiple links to same target deduplicated")
    func deduplicateLinks() {
        let files = [
            makeFile(id: "a.md", title: "A", content: "See [[B]] and [[B]] again [[B]]"),
            makeFile(id: "b.md", title: "B", content: ""),
        ]
        let vm = VaultManager()
        let graph = vm.testBuildGraph(from: files)
        #expect(graph.edges.count == 1) // deduplicated
    }

    @Test("Heading anchor stripped from link")
    func headingAnchorStripped() {
        let files = [
            makeFile(id: "a.md", title: "A", content: "See [[B#Section One]]"),
            makeFile(id: "b.md", title: "B", content: "Content"),
        ]
        let vm = VaultManager()
        let graph = vm.testBuildGraph(from: files)
        #expect(graph.edges.count == 1)
        #expect(graph.edges[0].target == "b.md")
    }

    @Test("Subfolder link resolution")
    func subfolderLinkResolution() {
        let files = [
            makeFile(id: "a.md", title: "A", content: "Link to [[Deep]]"),
            VaultFile(
                id: "sub/deep.md", url: URL(fileURLWithPath: "/vault/sub/deep.md"),
                title: "Deep", relativePath: "sub/deep.md", folderPath: "sub",
                createdDate: Date(), modifiedDate: Date(), contentSnippet: "", content: ""
            ),
        ]
        let vm = VaultManager()
        let graph = vm.testBuildGraph(from: files)
        #expect(graph.edges.count == 1)
    }

    @Test("Graph JSON serialization works")
    func jsonSerialization() {
        let graph = VaultGraph(
            nodes: [GraphNode(id: "a", title: "A", folder: "root", connectionCount: 1)],
            edges: [GraphEdge(source: "a", target: "b")]
        )
        let json = graph.toJSON()
        #expect(json != nil)
        #expect(json!.contains("\"id\":\"a\""))
    }
}
