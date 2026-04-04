import SwiftUI

/// Bottom sheet overlay for active voice chat
struct VoiceChatOverlay: View {
    let file: VaultFile
    @Binding var isPresented: Bool
    @Environment(VaultManager.self) private var vault
    @State private var service = VoiceProviderFactory.makeRealtime(vendor: VoiceSettings.shared.realtimeVendor)
    @State private var showSummarizeSheet = false
    @State private var showApiKeyPrompt = false
    @State private var selectedVoice = VoiceSettings.shared.selectedVoice
    @State private var chatStyle: SummarizationStyle = .conversational

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Voice Chat")
                    .font(.headline)
                Spacer()
                if !service.transcript.isEmpty {
                    Button("Summarize") {
                        showSummarizeSheet = true
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.obsidianPurple)
                }
                Button {
                    service.disconnect()
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            // Status indicator
            VoiceStatusIndicator(state: service.state)

            // Transcript preview
            VoiceTranscriptView(
                transcript: service.transcript,
                maxHeight: 150
            )

            // Controls
            HStack(spacing: 24) {
                // Chat style picker
                Menu {
                    ForEach(SummarizationStyle.allCases) { style in
                        Button {
                            chatStyle = style
                        } label: {
                            HStack {
                                Text(style.rawValue)
                                if style == chatStyle { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    Divider()
                    VoicePickerMenu(selectedVoice: $selectedVoice)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title3)
                        Text(chatStyle.rawValue)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }

                // Main action button
                VoiceMicButton(
                    state: service.state,
                    size: 64,
                    onTap: { handleMainAction() }
                )

                // Summarize button (large)
                Button {
                    showSummarizeSheet = true
                } label: {
                    Image(systemName: "doc.text")
                        .font(.title2)
                        .foregroundStyle(service.transcript.isEmpty ? .tertiary : .secondary)
                }
                .disabled(service.transcript.isEmpty)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
        .sheet(isPresented: $showSummarizeSheet) {
            VoiceSummarizeSheet(
                file: file,
                transcript: service.transcript,
                initialStyle: chatStyle,
                isPresented: $showSummarizeSheet
            )
        }
        .voiceAPIKeyPrompt(isPresented: $showApiKeyPrompt) {
            startVoiceChat()
        }
        .onAppear {
            if APIKeychain.hasKey(vendor: VoiceSettings.shared.realtimeVendor.rawValue) {
                startVoiceChat()
            } else {
                showApiKeyPrompt = true
            }
        }
        .onDisappear {
            service.disconnect()
        }
        .onChange(of: selectedVoice) {
            service.voice = selectedVoice
        }
    }

    // MARK: - Actions

    private func handleMainAction() {
        switch service.state {
        case .disconnected, .error:
            startVoiceChat()
        case .connected, .listening, .responding:
            service.disconnect()
        case .connecting:
            break
        }
    }

    private func startVoiceChat() {
        guard let apiKey = APIKeychain.load(vendor: VoiceSettings.shared.realtimeVendor.rawValue) else {
            showApiKeyPrompt = true
            return
        }
        let fileURL = file.url
        let fileTitle = file.title
        let style = chatStyle
        let vaultURL = vault.vaultURL
        service.voice = selectedVoice
        // Read file and parse markdown off main thread to avoid blocking UI
        Task.detached(priority: .userInitiated) { [service] in
            let rawContent = try? String(contentsOf: fileURL, encoding: .utf8)
            let (_, body) = MarkdownParser.extractFrontmatter(rawContent ?? "")
            let instructions = style.realtimeSystemPrompt(documentContent: body, documentTitle: fileTitle, vaultURL: vaultURL)
            await MainActor.run {
                service.connect(apiKey: apiKey, documentContent: body, systemInstructions: instructions)
            }
        }
    }
}
