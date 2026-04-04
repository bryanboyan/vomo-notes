import Foundation

/// Configuration for starting a voice session
struct VoiceSessionConfig {
    let systemInstructions: String
    let documentContent: String
    let tools: [[String: Any]]

    init(systemInstructions: String, documentContent: String = "", tools: [[String: Any]] = []) {
        self.systemInstructions = systemInstructions
        self.documentContent = documentContent
        self.tools = tools
    }
}

/// Unified session lifecycle wrapping a RealtimeVoiceProvider.
/// Manages connect/disconnect, PTT/interactive mode, audio state.
@Observable
final class VoiceSession {
    private(set) var provider: RealtimeVoiceProvider

    private(set) var inputMode: VoiceInputMode = .ptt
    private(set) var isPTTActive = false

    var state: VoiceChatState { provider.state }
    var transcript: TranscriptManager { provider.transcript }

    /// Hook for external message interception (tool calls)
    var onMessage: ((String, [String: Any]) -> Bool)? {
        get { provider.onMessage }
        set { provider.onMessage = newValue }
    }

    init() {
        let settings = VoiceSettings.shared
        provider = VoiceProviderFactory.makeRealtime(vendor: settings.realtimeVendor)
        provider.voice = settings.selectedVoice
    }

    /// Recreate the provider if the vendor has changed since init
    func refreshProvider() {
        let settings = VoiceSettings.shared
        provider = VoiceProviderFactory.makeRealtime(vendor: settings.realtimeVendor)
        provider.voice = settings.selectedVoice
    }

    // MARK: - Connect / Disconnect

    func connect(apiKey: String, config: VoiceSessionConfig) {
        let settings = VoiceSettings.shared
        provider.voice = settings.selectedVoice
        provider.tools = config.tools
        provider.connect(apiKey: apiKey, documentContent: config.documentContent, systemInstructions: config.systemInstructions)
    }

    func disconnect() {
        provider.disconnect()
        isPTTActive = false
    }

    // MARK: - Voice Input Mode

    func switchToInteractive() {
        inputMode = .interactive
        isPTTActive = false
        provider.isCapturingAudio = true
        provider.updateTurnDetection(enabled: true)
    }

    func switchToPTT() {
        inputMode = .ptt
        isPTTActive = false
        provider.isCapturingAudio = false
        provider.updateTurnDetection(enabled: false)
    }

    func startPTT() {
        guard inputMode == .ptt else { return }
        isPTTActive = true
        provider.stopPlayback()
        provider.clearAudioBuffer()
        provider.isCapturingAudio = true
    }

    func stopPTT() {
        guard inputMode == .ptt else { return }
        isPTTActive = false
        provider.isCapturingAudio = false
        provider.commitAudioBuffer()
    }

    // MARK: - Text Input

    func sendTextMessage(_ text: String) {
        guard !text.isEmpty else { return }
        transcript.addUserTurn(text)

        Task {
            let item: [String: Any] = [
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": text]
                    ]
                ] as [String: Any]
            ]
            await provider.sendJSON(item)
            await provider.sendJSON(["type": "response.create"])
        }
    }
}
