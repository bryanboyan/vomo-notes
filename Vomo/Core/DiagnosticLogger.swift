import Foundation
import UIKit

/// Severity level for diagnostic entries
enum DiagnosticLevel: String, Codable {
    case info
    case warning
    case error
    case crash
}

/// A single diagnostic log entry
struct DiagnosticEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let level: DiagnosticLevel
    let category: String
    let message: String
    let file: String?
    let line: Int?

    init(level: DiagnosticLevel, category: String, message: String, file: String? = nil, line: Int? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.category = category
        self.message = message
        self.file = file
        self.line = line
    }

    var icon: String {
        switch level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .crash: return "bolt.trianglebadge.exclamationmark"
        }
    }

    var formattedTimestamp: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return fmt.string(from: timestamp)
    }

    var oneLiner: String {
        "[\(formattedTimestamp)] \(level.rawValue.uppercased()) [\(category)] \(message)"
    }
}

/// Central diagnostic logger. Captures errors, warnings, and crash signals.
/// Access via `DiagnosticLogger.shared`.
@Observable
final class DiagnosticLogger {
    static let shared = DiagnosticLogger()

    private(set) var entries: [DiagnosticEntry] = []
    private let maxEntries = 500
    private let lock = NSLock()

    /// Persistent log file URL
    private var logFileURL: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("vomo_diagnostics.log")
    }

    private init() {
        installCrashHandlers()
        loadPersistedEntries()
    }

    // MARK: - Logging

    func log(_ level: DiagnosticLevel, category: String, message: String, file: String? = nil, line: Int? = nil) {
        let entry = DiagnosticEntry(level: level, category: category, message: message, file: file, line: line)
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()

        // Append to persistent log
        appendToLogFile(entry)
    }

    func info(_ category: String, _ message: String) {
        log(.info, category: category, message: message)
    }

    func warning(_ category: String, _ message: String) {
        log(.warning, category: category, message: message)
    }

    func error(_ category: String, _ message: String, file: String? = #fileID, line: Int? = #line) {
        log(.error, category: category, message: message, file: file, line: line)
    }

    func crash(_ category: String, _ message: String) {
        log(.crash, category: category, message: message)
    }

    // MARK: - Export

    /// Full log text suitable for sharing/emailing
    func exportText() -> String {
        var lines: [String] = []
        lines.append("=== Vomo Diagnostic Report ===")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Device: \(UIDevice.current.model) (\(UIDevice.current.systemName) \(UIDevice.current.systemVersion))")
        lines.append("App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
        lines.append("Entries: \(entries.count)")
        lines.append("")
        lines.append("--- Log Entries ---")

        lock.lock()
        let snapshot = entries
        lock.unlock()

        for entry in snapshot {
            var line = entry.oneLiner
            if let file = entry.file, let lineNum = entry.line {
                line += " (\(file):\(lineNum))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        // Clear persisted log
        if let url = logFileURL {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    var errorCount: Int {
        lock.lock()
        let count = entries.filter { $0.level == .error || $0.level == .crash }.count
        lock.unlock()
        return count
    }

    var warningCount: Int {
        lock.lock()
        let count = entries.filter { $0.level == .warning }.count
        lock.unlock()
        return count
    }

    // MARK: - Persistence

    private func appendToLogFile(_ entry: DiagnosticEntry) {
        guard let url = logFileURL else { return }
        let line = entry.oneLiner + "\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func loadPersistedEntries() {
        guard let url = logFileURL,
              let content = try? String(contentsOf: url, encoding: .utf8),
              !content.isEmpty else { return }

        // Only load crash entries from previous session (to show on restart)
        let lines = content.components(separatedBy: "\n").filter { $0.contains("CRASH") }
        if !lines.isEmpty {
            log(.info, category: "Diagnostics", message: "Found \(lines.count) crash entries from previous session")
        }
    }

    // MARK: - Crash Signal Handlers

    private func installCrashHandlers() {
        // Uncaught exception handler
        NSSetUncaughtExceptionHandler { exception in
            let message = "\(exception.name.rawValue): \(exception.reason ?? "unknown")\n\(exception.callStackSymbols.prefix(10).joined(separator: "\n"))"
            DiagnosticLogger.shared.crash("Exception", message)
        }

        // POSIX signal handlers for common crash signals
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP]
        for sig in signals {
            signal(sig) { sigNum in
                let name: String
                switch sigNum {
                case SIGABRT: name = "SIGABRT"
                case SIGSEGV: name = "SIGSEGV"
                case SIGBUS: name = "SIGBUS"
                case SIGFPE: name = "SIGFPE"
                case SIGILL: name = "SIGILL"
                case SIGTRAP: name = "SIGTRAP"
                default: name = "SIG\(sigNum)"
                }
                DiagnosticLogger.shared.crash("Signal", "Received \(name)")
                // Re-raise to get default behavior (crash report generation)
                signal(sigNum, SIG_DFL)
                raise(sigNum)
            }
        }
    }
}
