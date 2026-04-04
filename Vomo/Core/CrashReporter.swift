import Foundation
import UIKit

/// Collects diagnostic entries from a voice session and uploads them to a remote endpoint.
/// Designed to capture voice-mode crashes/errors and send them to TestFlight/analytics.
final class CrashReporter {
    static let shared = CrashReporter()

    /// Remote endpoint for crash reports. Configurable per environment.
    var reportURL: URL? {
        // Default: uses the app's configured crash report endpoint from Info.plist
        // or a built-in default. Override for testing.
        if let urlString = Bundle.main.infoDictionary?["VomoCrashReportURL"] as? String,
           let url = URL(string: urlString) {
            return url
        }
        return nil
    }

    /// Track when the current voice session started
    private var sessionStartDate: Date?
    private var sessionStartEntryCount: Int = 0

    private init() {}

    // MARK: - Session Lifecycle

    /// Call when a voice session begins
    func voiceSessionStarted() {
        sessionStartDate = Date()
        sessionStartEntryCount = DiagnosticLogger.shared.entries.count
    }

    /// Call when a voice session ends. Checks for errors and reports if any occurred.
    func voiceSessionEnded(lastState: VoiceChatState) {
        let logger = DiagnosticLogger.shared
        let allEntries = logger.entries

        // Collect entries logged during this session
        let sessionEntries: [DiagnosticEntry]
        if sessionStartEntryCount < allEntries.count {
            sessionEntries = Array(allEntries[sessionStartEntryCount...])
        } else {
            sessionEntries = []
        }

        // Filter to errors and crashes from this session
        let errorEntries = sessionEntries.filter { $0.level == .error || $0.level == .crash }

        // Also check if we ended in an error state
        let endedInError: Bool
        if case .error = lastState {
            endedInError = true
        } else {
            endedInError = false
        }

        guard !errorEntries.isEmpty || endedInError else {
            // Clean session, nothing to report
            sessionStartDate = nil
            return
        }

        // Build and send report
        let report = buildReport(
            sessionEntries: sessionEntries,
            errorEntries: errorEntries,
            lastState: lastState
        )
        sendReport(report)

        sessionStartDate = nil
    }

    // MARK: - Report Building

    private func buildReport(
        sessionEntries: [DiagnosticEntry],
        errorEntries: [DiagnosticEntry],
        lastState: VoiceChatState
    ) -> [String: Any] {
        let device = UIDevice.current
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        let sessionDuration: Double
        if let start = sessionStartDate {
            sessionDuration = Date().timeIntervalSince(start)
        } else {
            sessionDuration = 0
        }

        let stateString: String
        switch lastState {
        case .disconnected: stateString = "disconnected"
        case .connecting: stateString = "connecting"
        case .connected: stateString = "connected"
        case .listening: stateString = "listening"
        case .responding: stateString = "responding"
        case .error(let msg): stateString = "error: \(msg)"
        }

        // Serialize entries
        let entriesPayload: [[String: Any]] = errorEntries.map { entry in
            [
                "timestamp": ISO8601DateFormatter().string(from: entry.timestamp),
                "level": entry.level.rawValue,
                "category": entry.category,
                "message": entry.message,
                "file": entry.file ?? "",
                "line": entry.line ?? 0
            ] as [String: Any]
        }

        // Include a summary of ALL session entries (info/warning too) for context
        let contextPayload: [[String: Any]] = sessionEntries.suffix(50).map { entry in
            [
                "timestamp": ISO8601DateFormatter().string(from: entry.timestamp),
                "level": entry.level.rawValue,
                "category": entry.category,
                "message": String(entry.message.prefix(200))
            ] as [String: Any]
        }

        return [
            "device": "\(device.model) (\(device.systemName) \(device.systemVersion))",
            "app_version": "\(appVersion) (\(buildNumber))",
            "session_duration_seconds": Int(sessionDuration),
            "voice_state_at_end": stateString,
            "error_count": errorEntries.count,
            "errors": entriesPayload,
            "session_context": contextPayload,
            "reported_at": ISO8601DateFormatter().string(from: Date())
        ] as [String: Any]
    }

    // MARK: - Network Upload

    private func sendReport(_ report: [String: Any]) {
        guard let url = reportURL else {
            // No endpoint configured — persist locally for manual export
            DiagnosticLogger.shared.info("CrashReporter", "Voice session had \(report["error_count"] ?? 0) errors (no remote endpoint configured)")
            persistLocally(report)
            return
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: report) else {
            DiagnosticLogger.shared.warning("CrashReporter", "Failed to serialize crash report")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        // Use background-quality URLSession so the upload can complete even if app is backgrounded
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.allowsConstrainedNetworkAccess = true
        let session = URLSession(configuration: config)

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                DiagnosticLogger.shared.warning("CrashReporter", "Upload failed: \(error.localizedDescription)")
                // Persist locally as fallback
                self.persistLocally(report)
                return
            }
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                    DiagnosticLogger.shared.info("CrashReporter", "Crash report uploaded successfully")
                } else {
                    DiagnosticLogger.shared.warning("CrashReporter", "Upload returned status \(httpResponse.statusCode)")
                    self.persistLocally(report)
                }
            }
        }
        task.resume()
        DiagnosticLogger.shared.info("CrashReporter", "Uploading voice crash report (\(jsonData.count) bytes)")
    }

    /// Persist crash report to local file for later manual export
    private func persistLocally(_ report: [String: Any]) {
        guard let dir = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let reportsDir = dir.appendingPathComponent("crash_reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)

        let filename = "voice_crash_\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).json"
        let fileURL = reportsDir.appendingPathComponent(filename)

        if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
            try? data.write(to: fileURL)
            DiagnosticLogger.shared.info("CrashReporter", "Crash report saved locally: \(filename)")
        }
    }

    // MARK: - Pending Reports

    /// Check for locally persisted crash reports and attempt to upload them
    func uploadPendingReports() {
        guard let url = reportURL else { return }
        guard let dir = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let reportsDir = dir.appendingPathComponent("crash_reports", isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: nil) else { return }
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        guard !jsonFiles.isEmpty else { return }

        DiagnosticLogger.shared.info("CrashReporter", "Found \(jsonFiles.count) pending crash reports, uploading...")

        for file in jsonFiles {
            guard let data = try? Data(contentsOf: file),
                  let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let jsonData = try? JSONSerialization.data(withJSONObject: report) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData

            let fileToDelete = file
            URLSession.shared.dataTask(with: request) { _, response, error in
                if error == nil, let http = response as? HTTPURLResponse, (200...201).contains(http.statusCode) {
                    try? FileManager.default.removeItem(at: fileToDelete)
                }
            }.resume()
        }
    }
}
