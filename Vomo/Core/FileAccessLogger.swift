import SwiftUI

@Observable
final class FileAccessLogger {
    static let shared = FileAccessLogger()

    struct AccessEvent: Identifiable, Equatable {
        let id = UUID()
        let category: AccessCategory
        let summary: String
        let detail: String?
        let timestamp: Date = .now

        static func == (lhs: AccessEvent, rhs: AccessEvent) -> Bool {
            lhs.id == rhs.id
        }
    }

    enum AccessCategory {
        case search, read, scan, agent, dataview

        var icon: String {
            switch self {
            case .search: "magnifyingglass"
            case .read: "doc.text"
            case .scan: "folder"
            case .agent: "sparkle"
            case .dataview: "tablecells"
            }
        }

        var color: Color {
            switch self {
            case .search: .orange
            case .read: .blue
            case .scan: .secondary
            case .agent: .purple
            case .dataview: .teal
            }
        }

        var verb: String {
            switch self {
            case .search: "Searching"
            case .read: "Reading"
            case .scan: "Scanning"
            case .agent: "Agent opened"
            case .dataview: "Querying"
            }
        }
    }

    var currentHint: AccessEvent?
    private var pendingEvents: [AccessEvent] = []
    private var coalesceTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    func log(_ category: AccessCategory, summary: String, detail: String? = nil) {
        let event = AccessEvent(category: category, summary: summary, detail: detail)
        enqueue(event)
    }

    private func enqueue(_ event: AccessEvent) {
        pendingEvents.append(event)
        coalesceTask?.cancel()
        coalesceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            flush()
        }
    }

    @MainActor private func flush() {
        guard !pendingEvents.isEmpty else { return }
        dismissTask?.cancel()

        if pendingEvents.count == 1 {
            withAnimation(.spring(duration: 0.25)) {
                currentHint = pendingEvents[0]
            }
        } else {
            let category = pendingEvents[0].category
            withAnimation(.spring(duration: 0.25)) {
                currentHint = AccessEvent(
                    category: category,
                    summary: "\(pendingEvents.count) files",
                    detail: nil
                )
            }
        }
        pendingEvents.removeAll()
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut(duration: 0.3)) {
                currentHint = nil
            }
        }
    }
}
