import SwiftUI

/// Bottom panel of the voice search split view — shows status, transcript, and controls
struct AgentVoiceConsole: View {
    let service: AgentVoiceService
    var onClose: (() -> Void)?
    @State private var showApiKeyPrompt = false
    @State private var selectedVoice = VoiceSettings.shared.selectedVoice
    @State private var textInput = ""
    @State private var showSettings = false
    @FocusState private var isTextInputFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            // Status indicator
            VoiceStatusIndicator(
                state: service.state,
                inputMode: service.inputMode,
                toolActivity: service.isToolExecuting ? service.currentToolActivity : nil
            )

            // Transcript
            transcriptView

            Spacer(minLength: 0)

            // Text input
            if service.state != .disconnected {
                textInputBar
            }

            // Controls
            controlsView
        }
        .padding()
        .background(.ultraThinMaterial)
        .voiceAPIKeyPrompt(isPresented: $showApiKeyPrompt) { }
        .sheet(isPresented: $showSettings) {
            VoiceSettingsSheet(selectedVoice: $selectedVoice, service: service)
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptView: some View {
        if !service.transcript.isEmpty || !service.transcript.currentAssistantText.isEmpty {
            VoiceTranscriptView(
                transcript: service.transcript,
                toolActivity: service.isToolExecuting ? service.currentToolActivity : nil
            )
        } else {
            // Smart empty state with suggestions
            VStack(spacing: 12) {
                Text("Try saying:")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 8) {
                    suggestionBubble("Find my notes about the quarterly review")
                    suggestionBubble("What did I write last week?")
                    suggestionBubble("Show me notes tagged meeting")
                }
            }
            .padding(.top, 8)
        }
    }

    private func suggestionBubble(_ text: String) -> some View {
        Text("\"\(text)\"")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Text Input

    private var textInputBar: some View {
        HStack(spacing: 8) {
            TextField("Type a message...", text: $textInput)
                .focused($isTextInputFocused)
                .font(.caption)
                .submitLabel(.send)
                .onSubmit { sendText() }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 10))

            if !textInput.isEmpty {
                Button {
                    sendText()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.obsidianPurple)
                }
            }
        }
    }

    private func sendText() {
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        service.sendTextMessage(text)
        textInput = ""
    }

    // MARK: - Controls

    private var controlsView: some View {
        HStack {
            // Left: Settings
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            // Center: Main action button
            VoiceMicButton(
                state: service.state,
                inputMode: service.inputMode,
                isPTTActive: service.isPTTActive,
                size: 56,
                onTap: { handleInteractiveAction() },
                onPTTStart: { service.startPTT() },
                onPTTEnd: { service.stopPTT() }
            )

            Spacer()

            // Right: X (Interactive) or Switch-to-Live (PTT)
            if service.inputMode == .ptt && service.state != .disconnected {
                Button {
                    service.switchToInteractive()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "waveform")
                            .font(.title3)
                        Text("Live")
                            .font(.caption2)
                    }
                    .foregroundStyle(.green)
                    .frame(width: 44, height: 44)
                }
            } else {
                Button {
                    onClose?()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: 56, height: 56)
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(service.state == .disconnected)
                .opacity(service.state == .disconnected ? 0.3 : 1)
            }
        }
    }

    // MARK: - Actions

    private func handleInteractiveAction() {
        switch service.state {
        case .disconnected, .error:
            guard APIKeychain.hasKey(vendor: VoiceSettings.shared.realtimeVendor.rawValue) else {
                showApiKeyPrompt = true
                return
            }
            break
        case .connecting:
            break
        case .connected, .listening, .responding:
            service.switchToPTT()
        }
    }
}

// MARK: - Voice Settings Sheet

struct VoiceSettingsSheet: View {
    @Binding var selectedVoice: String
    let service: AgentVoiceService
    @Environment(\.dismiss) private var dismiss
    @State private var customRules = VoiceSettings.shared.searchCustomRules
    @State private var hasApiKey = APIKeychain.hasKey(vendor: VoiceSettings.shared.realtimeVendor.rawValue)
    @State private var apiKeyInput = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Voice") {
                    ForEach(VoiceSettings.voices, id: \.self) { voice in
                        Button {
                            selectedVoice = voice
                            service.provider.voice = voice
                            VoiceSettings.shared.selectedVoice = voice
                        } label: {
                            HStack {
                                Text(voice)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if voice == selectedVoice {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.obsidianPurple)
                                }
                            }
                        }
                    }
                }

                Section {
                    TextEditor(text: $customRules)
                        .font(.caption)
                        .frame(minHeight: 100)
                } header: {
                    Text("Custom Rules")
                } footer: {
                    Text("These rules are added to the AI's system prompt. Changes apply on next connection.")
                }

                Section("API Key") {
                    if hasApiKey {
                        HStack {
                            Text("Grok API Key")
                            Spacer()
                            Text("Configured")
                                .foregroundStyle(.green)
                        }
                        Button("Update Key", role: .destructive) {
                            hasApiKey = false
                        }
                    } else {
                        SecureField("xai-...", text: $apiKeyInput)
                        Button("Save") {
                            if !apiKeyInput.isEmpty {
                                _ = APIKeychain.save(vendor: VoiceSettings.shared.realtimeVendor.rawValue, key: apiKeyInput)
                                hasApiKey = true
                                apiKeyInput = ""
                            }
                        }
                        .disabled(apiKeyInput.isEmpty)
                    }
                }
            }
            .navigationTitle("Voice Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        VoiceSettings.shared.searchCustomRules = customRules
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
