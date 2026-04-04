import SwiftUI

/// Shake-to-report diagnostic view. Shows collected errors/warnings and allows export.
struct DiagnosticReportView: View {
    @Binding var isPresented: Bool
    let logger = DiagnosticLogger.shared
    @State private var showShareSheet = false
    @State private var filterLevel: DiagnosticLevel? = nil

    private var filteredEntries: [DiagnosticEntry] {
        let all = logger.entries
        guard let level = filterLevel else { return all.reversed() }
        return all.filter { $0.level == level }.reversed()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Stats bar
                statsBar
                Divider()

                // Filter chips
                filterBar
                    .padding(.vertical, 6)
                Divider()

                // Log entries
                if filteredEntries.isEmpty {
                    emptyState
                } else {
                    List(filteredEntries) { entry in
                        entryRow(entry)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showShareSheet = true
                        } label: {
                            Label("Export Log", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            copyToClipboard()
                        } label: {
                            Label("Copy to Clipboard", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) {
                            logger.clear()
                        } label: {
                            Label("Clear Logs", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                let text = logger.exportText()
                ShareSheet(text: text)
            }
        }
    }

    // MARK: - Stats Bar

    private var statsBar: some View {
        HStack(spacing: 16) {
            statBadge(count: logger.errorCount, label: "Errors", color: .red)
            statBadge(count: logger.warningCount, label: "Warnings", color: .orange)
            statBadge(count: logger.entries.count, label: "Total", color: .secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    private func statBadge(count: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(count > 0 ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(label: "All", level: nil)
                filterChip(label: "Crashes", level: .crash)
                filterChip(label: "Errors", level: .error)
                filterChip(label: "Warnings", level: .warning)
                filterChip(label: "Info", level: .info)
            }
            .padding(.horizontal)
        }
    }

    private func filterChip(label: String, level: DiagnosticLevel?) -> some View {
        Button {
            filterLevel = level
        } label: {
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    filterLevel == level ? Color.obsidianPurple : Color(.systemGray5),
                    in: Capsule()
                )
                .foregroundStyle(filterLevel == level ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Entry Row

    private func entryRow(_ entry: DiagnosticEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.icon)
                .font(.caption)
                .foregroundStyle(colorForLevel(entry.level))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.category)
                        .font(.caption.bold())
                    Spacer()
                    Text(entry.formattedTimestamp)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)

                if let file = entry.file, let line = entry.line {
                    Text("\(file):\(line)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func colorForLevel(_ level: DiagnosticLevel) -> Color {
        switch level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .crash: return .red
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.seal")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("No issues recorded")
                .font(.headline)
            Text("Errors, warnings, and crashes will appear here")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Actions

    private func copyToClipboard() {
        UIPasteboard.general.string = logger.exportText()
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Write to temp file for sharing
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("vomo_diagnostics.txt")
        try? text.write(to: tempURL, atomically: true, encoding: .utf8)
        return UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Shake Gesture Detection

/// View modifier that adds shake-to-report functionality.
struct ShakeToReportModifier: ViewModifier {
    @State private var showDiagnostics = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                showDiagnostics = true
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticReportView(isPresented: $showDiagnostics)
            }
    }
}

extension Notification.Name {
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

// UIWindow extension to broadcast shake events as notifications
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}

extension View {
    /// Adds shake-to-report diagnostic overlay to the view
    func shakeToReport() -> some View {
        modifier(ShakeToReportModifier())
    }
}
