import Foundation
import CryptoKit

struct CachedFileMetadata: Codable {
    let relativePath: String
    let title: String
    let folderPath: String
    var createdDate: Date? = nil
    let modifiedDate: Date
    let contentSnippet: String
}

struct CacheManifest: Codable {
    var version: Int = 1
    var vaultName: String = ""
    var lastFullSync: Date?
    var files: [String: CachedFileMetadata] = [:]
}

final class VaultCache {
    let cacheRoot: URL
    private var manifest: CacheManifest

    init(vaultURL: URL) {
        let hash = Insecure.MD5.hash(data: Data(vaultURL.path.utf8))
        let vaultID = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheRoot = appSupport.appendingPathComponent("VaultCache/\(vaultID)")
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheRoot.appendingPathComponent("files"), withIntermediateDirectories: true)

        // Load manifest once into memory
        let manifestURL = cacheRoot.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let loaded = try? JSONDecoder().decode(CacheManifest.self, from: data) {
            manifest = loaded
        } else {
            manifest = CacheManifest()
        }
    }

    private var manifestURL: URL { cacheRoot.appendingPathComponent("manifest.json") }
    private var filesRoot: URL { cacheRoot.appendingPathComponent("files") }

    // MARK: - Manifest (in-memory, flush to disk explicitly)

    func flushManifest() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    // MARK: - File Content

    func cachedContentPath(for relativePath: String) -> URL {
        filesRoot.appendingPathComponent(relativePath)
    }

    func readCachedContent(relativePath: String) -> String? {
        let path = cachedContentPath(for: relativePath)
        return try? String(contentsOf: path, encoding: .utf8)
    }

    func cacheFile(relativePath: String, content: String, metadata: CachedFileMetadata) {
        let path = cachedContentPath(for: relativePath)
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? content.write(to: path, atomically: true, encoding: .utf8)
        manifest.files[relativePath] = metadata
    }

    // MARK: - Bulk Operations

    func loadAllCachedFiles(vaultRootURL: URL) -> [VaultFile] {
        manifest.files.values.compactMap { meta in
            let url = vaultRootURL.appendingPathComponent(meta.relativePath)
            let cachedContent = readCachedContent(relativePath: meta.relativePath)
            return VaultFile(
                id: meta.relativePath,
                url: url,
                title: meta.title,
                relativePath: meta.relativePath,
                folderPath: meta.folderPath,
                createdDate: meta.createdDate ?? meta.modifiedDate,
                modifiedDate: meta.modifiedDate,
                contentSnippet: meta.contentSnippet,
                content: cachedContent
            )
        }.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    func isCached(relativePath: String, modifiedDate: Date) -> Bool {
        guard let cached = manifest.files[relativePath] else { return false }
        return cached.modifiedDate >= modifiedDate
    }

    func pruneDeletedFiles(currentPaths: Set<String>) {
        let stale = Set(manifest.files.keys).subtracting(currentPaths)
        for path in stale {
            manifest.files.removeValue(forKey: path)
            try? FileManager.default.removeItem(at: cachedContentPath(for: path))
        }
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        manifest = CacheManifest()
    }
}
