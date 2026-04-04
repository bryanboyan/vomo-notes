import Foundation

struct PendingFile {
    let icloudURL: URL      // .Something.md.icloud
    let realURL: URL        // Something.md
    let relativePath: String
}

@Observable
final class ICloudDownloadMonitor {
    var totalFiles: Int = 0
    var downloadedFiles: Int = 0
    var isMonitoring: Bool = false
    var progress: Double { totalFiles == 0 ? 1.0 : Double(downloadedFiles) / Double(totalFiles) }

    private var pendingFiles: [PendingFile] = []
    private var pollTask: Task<Void, Never>?
    private var onFileDownloaded: ((PendingFile) -> Void)?
    private var onComplete: (() -> Void)?

    func startMonitoring(
        files: [PendingFile],
        vaultURL: URL,
        isLocalPath: Bool,
        timeout: TimeInterval = 30,
        onFileDownloaded: @escaping (PendingFile) -> Void,
        onComplete: @escaping () -> Void = {}
    ) {
        self.pendingFiles = files
        self.totalFiles = files.count
        self.downloadedFiles = 0
        self.isMonitoring = true
        self.onFileDownloaded = onFileDownloaded
        self.onComplete = onComplete

        // Trigger downloads in batches of 50
        let fm = FileManager.default
        if !isLocalPath {
            _ = vaultURL.startAccessingSecurityScopedResource()
        }

        for batch in stride(from: 0, to: files.count, by: 50) {
            let end = min(batch + 50, files.count)
            for i in batch..<end {
                try? fm.startDownloadingUbiquitousItem(at: files[i].realURL)
            }
        }

        // Start polling
        let startTime = Date()
        pollTask = Task { [weak self] in
            guard let self else { return }
            var pollInterval: UInt64 = 1_000_000_000 // 1 second

            while !Task.isCancelled && !self.pendingFiles.isEmpty {
                // Timeout: stop monitoring if downloads stall
                if Date().timeIntervalSince(startTime) > timeout {
                    print("⏰ iCloud download timeout after \(Int(timeout))s — \(self.pendingFiles.count) files still pending")
                    break
                }

                try? await Task.sleep(nanoseconds: pollInterval)

                var newlyDownloaded: [PendingFile] = []
                self.pendingFiles.removeAll { file in
                    if fm.fileExists(atPath: file.realURL.path) {
                        newlyDownloaded.append(file)
                        return true
                    }
                    return false
                }

                if !newlyDownloaded.isEmpty {
                    await MainActor.run {
                        self.downloadedFiles += newlyDownloaded.count
                    }
                    for file in newlyDownloaded {
                        self.onFileDownloaded?(file)
                    }
                }

                // Adaptive polling: slow down as we near completion
                let pct = Double(self.downloadedFiles) / Double(max(1, self.totalFiles))
                if pct > 0.95 {
                    pollInterval = 5_000_000_000 // 5s
                } else if pct > 0.8 {
                    pollInterval = 2_000_000_000 // 2s
                }
            }

            if !isLocalPath {
                vaultURL.stopAccessingSecurityScopedResource()
            }

            await MainActor.run {
                self.isMonitoring = false
                self.onComplete?()
            }
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        isMonitoring = false
    }
}
