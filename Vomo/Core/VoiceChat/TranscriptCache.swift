import Foundation

/// A persisted voice transcript with metadata
struct CachedTranscript: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    let recordingMode: RecordingMode
    var turns: [TranscriptTurn]
    var savedAsNote: Bool
    var notePath: String?

    var formattedTranscript: String {
        turns.map { turn in
            let role = turn.role == .user ? "User" : "Assistant"
            return "\(role): \(turn.text)"
        }.joined(separator: "\n\n")
    }
}

/// LRU cache for voice transcripts, persisted to disk
@Observable
final class TranscriptCache {
    private(set) var transcripts: [CachedTranscript] = []
    private let maxSize = 50
    private let cacheDir: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDir = appSupport.appendingPathComponent("TranscriptCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        loadIndex()
    }

    /// Save a transcript from a voice session. Returns the cache ID.
    @discardableResult
    func save(_ transcript: TranscriptManager, mode: RecordingMode) -> UUID {
        let cached = CachedTranscript(
            id: UUID(),
            createdAt: Date(),
            recordingMode: mode,
            turns: transcript.turns,
            savedAsNote: false,
            notePath: nil
        )
        transcripts.insert(cached, at: 0)
        pruneIfNeeded()
        persist(cached)
        saveIndex()
        return cached.id
    }

    /// Load a transcript by ID, moving it to front of LRU
    func load(_ id: UUID) -> CachedTranscript? {
        guard let idx = transcripts.firstIndex(where: { $0.id == id }) else { return nil }
        let item = transcripts.remove(at: idx)
        transcripts.insert(item, at: 0)
        saveIndex()
        return item
    }

    /// Mark a transcript as saved to a note
    func markSaved(_ id: UUID, notePath: String) {
        guard let idx = transcripts.firstIndex(where: { $0.id == id }) else { return }
        transcripts[idx].savedAsNote = true
        transcripts[idx].notePath = notePath
        persist(transcripts[idx])
        saveIndex()
    }

    /// Delete a specific transcript
    func delete(_ id: UUID) {
        transcripts.removeAll { $0.id == id }
        let file = cacheDir.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: file)
        saveIndex()
    }

    // MARK: - Private

    private func pruneIfNeeded() {
        while transcripts.count > maxSize {
            // Prefer evicting saved transcripts first
            if let idx = transcripts.lastIndex(where: { $0.savedAsNote }) {
                let item = transcripts.remove(at: idx)
                removeFile(for: item.id)
            } else {
                let item = transcripts.removeLast()
                removeFile(for: item.id)
            }
        }
    }

    private func persist(_ transcript: CachedTranscript) {
        let file = cacheDir.appendingPathComponent("\(transcript.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(transcript) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func removeFile(for id: UUID) {
        let file = cacheDir.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: file)
    }

    private func loadIndex() {
        let indexFile = cacheDir.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexFile),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        transcripts = ids.compactMap { id in
            let file = cacheDir.appendingPathComponent("\(id.uuidString).json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(CachedTranscript.self, from: data)
        }
    }

    private func saveIndex() {
        let indexFile = cacheDir.appendingPathComponent("index.json")
        let ids = transcripts.map(\.id)
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? data.write(to: indexFile, options: .atomic)
    }
}
