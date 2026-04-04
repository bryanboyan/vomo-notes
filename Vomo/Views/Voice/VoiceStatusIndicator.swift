import SwiftUI

/// Colored dot + state text + LIVE/PTT badge — shared across all voice UIs
struct VoiceStatusIndicator: View {
    let state: VoiceChatState
    var inputMode: VoiceInputMode?
    var toolActivity: String?
    var contextLabel: String = ""

    var body: some View {
        HStack(spacing: 8) {
            statusContent

            Spacer()

            if let inputMode, state != .disconnected {
                modeBadge(inputMode)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch state {
        case .disconnected:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
            Text(contextLabel.isEmpty ? "Tap mic to start" : contextLabel)
        case .connecting:
            ProgressView()
                .controlSize(.small)
            Text("Connecting...")
        case .connected:
            pulsatingDot(color: .green)
            if let toolActivity {
                Text(toolActivity)
            } else if let inputMode, inputMode == .ptt {
                Text("Push to talk")
            } else {
                Text("Listening — speak to start")
            }
        case .listening:
            pulsatingDot(color: .blue)
            Text("Listening...")
        case .responding:
            pulsatingDot(color: Color.obsidianPurple)
            Text("Speaking...")
        case .error(let msg):
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(msg)
                .lineLimit(1)
        }
    }

    private func pulsatingDot(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private func modeBadge(_ mode: VoiceInputMode) -> some View {
        Text(mode == .interactive ? "LIVE" : "PTT")
            .font(.caption2.bold())
            .foregroundStyle(mode == .interactive ? .green : .orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (mode == .interactive ? Color.green : Color.orange).opacity(0.15),
                in: Capsule()
            )
    }
}
