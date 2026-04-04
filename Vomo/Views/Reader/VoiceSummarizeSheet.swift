import SwiftUI

/// Sheet for configuring and triggering conversation summarization
struct VoiceSummarizeSheet: View {
    let file: VaultFile
    let transcript: TranscriptManager
    var initialStyle: SummarizationStyle = .conversational
    @Binding var isPresented: Bool
    @Environment(VaultManager.self) private var vault

    @State private var selectedStyle: SummarizationStyle = .conversational

    init(file: VaultFile, transcript: TranscriptManager, initialStyle: SummarizationStyle = .conversational, isPresented: Binding<Bool>) {
        self.file = file
        self.transcript = transcript
        self.initialStyle = initialStyle
        self._isPresented = isPresented
        self._selectedStyle = State(initialValue: initialStyle)
    }
    @State private var selectedEditMode: EditMode = .append
    @State private var isSummarizing = false
    @State private var summary: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                // Transcript preview
                Section("Conversation (\(transcript.turnCount) turns)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(transcript.turns.prefix(10)) { turn in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(turn.role == .user ? "You:" : "Grok:")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(turn.role == .user ? .primary : Color.obsidianPurple)
                                        .frame(width: 40, alignment: .leading)
                                    Text(turn.text)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            if transcript.turnCount > 10 {
                                Text("... and \(transcript.turnCount - 10) more turns")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }

                // Summarization style
                Section("Summary Style") {
                    ForEach(SummarizationStyle.allCases) { style in
                        Button {
                            selectedStyle = style
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(style.rawValue)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(style.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedStyle == style {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.obsidianPurple)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Edit mode
                Section("Write to Note") {
                    ForEach(EditMode.allCases) { mode in
                        Button {
                            selectedEditMode = mode
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.rawValue)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(mode.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedEditMode == mode {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.obsidianPurple)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Summary preview (after generation)
                if let summary {
                    Section("Preview") {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Error
                if let error {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Summarize Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if summary != nil {
                        Button("Write to Note") {
                            writeToNote()
                        }
                        .disabled(isSummarizing)
                    } else {
                        Button("Summarize") {
                            generateSummary()
                        }
                        .disabled(isSummarizing || transcript.isEmpty)
                    }
                }
            }
            .overlay {
                if isSummarizing {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(summary == nil ? "Summarizing..." : "Writing to note...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func generateSummary() {
        guard let apiKey = APIKeychain.load(vendor: VoiceSettings.shared.realtimeVendor.rawValue) else { return }
        isSummarizing = true
        error = nil

        Task {
            do {
                let result = try await VoiceSummarizer.summarize(
                    transcript: transcript.formattedTranscript,
                    style: selectedStyle,
                    apiKey: apiKey,
                    vaultURL: vault.vaultURL
                )
                await MainActor.run {
                    summary = result
                    isSummarizing = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isSummarizing = false
                }
            }
        }
    }

    private func writeToNote() {
        guard let apiKey = APIKeychain.load(vendor: VoiceSettings.shared.realtimeVendor.rawValue), let summary else { return }
        isSummarizing = true
        error = nil

        Task {
            do {
                try await VoiceSummarizer.applyToDocument(
                    fileURL: file.url,
                    summary: summary,
                    editMode: selectedEditMode,
                    apiKey: apiKey,
                    vaultURL: vault.vaultURL
                )
                await MainActor.run {
                    isSummarizing = false
                    isPresented = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isSummarizing = false
                }
            }
        }
    }
}
