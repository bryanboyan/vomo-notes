import SwiftUI

/// Scrollable transcript with streaming text — shared across all voice UIs
struct VoiceTranscriptView: View {
    let transcript: TranscriptManager
    var maxHeight: CGFloat?
    var toolActivity: String?
    var showRoleLabels: Bool = false

    var body: some View {
        if !transcript.isEmpty || !transcript.currentAssistantText.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(transcript.turns.suffix(50)) { turn in
                            transcriptRow(turn: turn)
                                .id(turn.id)
                        }

                        // Tool activity inline
                        if let toolActivity {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .frame(width: 16)
                                Text(toolActivity)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .italic()
                            }
                            .id("tool-activity")
                        }

                        // Streaming assistant text
                        if !transcript.currentAssistantText.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(Color.obsidianPurple)
                                    .frame(width: 16)
                                Text(transcript.currentAssistantText)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .id("streaming")
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: maxHeight)
                .onChange(of: transcript.turns.count) {
                    withAnimation {
                        if let last = transcript.turns.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func transcriptRow(turn: TranscriptTurn) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: turn.role == .user ? "person.fill" : "sparkles")
                .font(.caption)
                .foregroundStyle(turn.role == .user ? .primary : Color.obsidianPurple)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                if showRoleLabels {
                    Text(turn.role == .user ? "You" : "Assistant")
                        .font(.caption2.bold())
                        .foregroundStyle(.tertiary)
                }
                Text(turn.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
