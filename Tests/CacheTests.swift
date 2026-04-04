import Testing
import Foundation
@testable import Vomo

@Suite("VaultCache")
struct CacheTests {

    private func makeTempCache() -> (VaultCache, URL) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-vault-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let cache = VaultCache(vaultURL: tmpDir)
        return (cache, tmpDir)
    }

    @Test("Cache file and read back")
    func cacheAndRead() {
        let (cache, _) = makeTempCache()
        let meta = CachedFileMetadata(
            relativePath: "test.md",
            title: "Test",
            folderPath: "",
            modifiedDate: Date(),
            contentSnippet: "Hello world"
        )
        cache.cacheFile(relativePath: "test.md", content: "# Hello\nWorld", metadata: meta)
        cache.flushManifest()

        let content = cache.readCachedContent(relativePath: "test.md")
        #expect(content == "# Hello\nWorld")
    }

    @Test("isCached returns true for cached file")
    func isCachedTrue() {
        let (cache, _) = makeTempCache()
        let now = Date()
        let meta = CachedFileMetadata(
            relativePath: "a.md", title: "A", folderPath: "", modifiedDate: now, contentSnippet: ""
        )
        cache.cacheFile(relativePath: "a.md", content: "content", metadata: meta)
        #expect(cache.isCached(relativePath: "a.md", modifiedDate: now))
    }

    @Test("isCached returns false for newer file on disk")
    func isCachedFalseWhenNewer() {
        let (cache, _) = makeTempCache()
        let old = Date(timeIntervalSince1970: 1000)
        let meta = CachedFileMetadata(
            relativePath: "a.md", title: "A", folderPath: "", modifiedDate: old, contentSnippet: ""
        )
        cache.cacheFile(relativePath: "a.md", content: "content", metadata: meta)
        let newer = Date(timeIntervalSince1970: 2000)
        #expect(!cache.isCached(relativePath: "a.md", modifiedDate: newer))
    }

    @Test("isCached returns false for uncached file")
    func isCachedFalseUncached() {
        let (cache, _) = makeTempCache()
        #expect(!cache.isCached(relativePath: "missing.md", modifiedDate: Date()))
    }

    @Test("Prune removes stale files")
    func pruneStaleFiles() {
        let (cache, _) = makeTempCache()
        let meta = CachedFileMetadata(
            relativePath: "old.md", title: "Old", folderPath: "", modifiedDate: Date(), contentSnippet: ""
        )
        cache.cacheFile(relativePath: "old.md", content: "old content", metadata: meta)
        cache.flushManifest()

        // Prune with empty current paths — should remove "old.md"
        cache.pruneDeletedFiles(currentPaths: Set())
        cache.flushManifest()

        #expect(!cache.isCached(relativePath: "old.md", modifiedDate: Date()))
        #expect(cache.readCachedContent(relativePath: "old.md") == nil)
    }

    @Test("loadAllCachedFiles returns VaultFile array")
    func loadAllCachedFiles() {
        let (cache, tmpDir) = makeTempCache()
        for i in 1...3 {
            let meta = CachedFileMetadata(
                relativePath: "note\(i).md", title: "Note \(i)", folderPath: "",
                modifiedDate: Date(), contentSnippet: "Content \(i)"
            )
            cache.cacheFile(relativePath: "note\(i).md", content: "# Note \(i)", metadata: meta)
        }
        cache.flushManifest()

        let files = cache.loadAllCachedFiles(vaultRootURL: tmpDir)
        #expect(files.count == 3)
        #expect(files.allSatisfy { $0.content != nil })
    }

    @Test("clearCache removes everything")
    func clearCache() {
        let (cache, _) = makeTempCache()
        let meta = CachedFileMetadata(
            relativePath: "x.md", title: "X", folderPath: "", modifiedDate: Date(), contentSnippet: ""
        )
        cache.cacheFile(relativePath: "x.md", content: "data", metadata: meta)
        cache.flushManifest()

        cache.clearCache()
        #expect(cache.readCachedContent(relativePath: "x.md") == nil)
        #expect(!cache.isCached(relativePath: "x.md", modifiedDate: Date()))
    }
}
