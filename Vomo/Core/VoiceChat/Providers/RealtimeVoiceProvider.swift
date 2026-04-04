import Foundation

/// Protocol for realtime voice conversation providers.
/// All vendors (xAI, OpenAI, Deepgram) conform to this.
protocol RealtimeVoiceProvider: AnyObject {
    // MARK: - Observable State
    var state: VoiceChatState { get }
    var transcript: TranscriptManager { get }

    // MARK: - Configuration
    var voice: String { get set }
    var isCapturingAudio: Bool { get set }
    var tools: [[String: Any]] { get set }

    // MARK: - Callbacks
    var onMessage: ((String, [String: Any]) -> Bool)? { get set }
    var onStateChange: ((VoiceChatState) -> Void)? { get set }
    var onTranscriptChange: ((TranscriptManager) -> Void)? { get set }
    var onAudioOutput: ((Data) -> Void)? { get set }

    // MARK: - Lifecycle
    func connect(apiKey: String, documentContent: String, systemInstructions: String?)
    func disconnect()

    // MARK: - Audio Control
    func commitAudioBuffer()
    func clearAudioBuffer()
    func updateTurnDetection(enabled: Bool)
    func stopPlayback()
    func injectAudioData(_ int16Data: Data)

    // MARK: - Messaging
    func sendJSON(_ dict: [String: Any]) async
    func sendFunctionOutput(callId: String, output: String)

    // MARK: - Voice List
    static func fetchVoices(apiKey: String) async throws -> [String]
}

/// Default implementation for sendFunctionOutput (shared OpenAI-compatible protocol)
extension RealtimeVoiceProvider {
    func sendFunctionOutput(callId: String, output: String) {
        let outputMessage: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": output
            ] as [String: Any]
        ]
        Task {
            await sendJSON(outputMessage)
            await sendJSON(["type": "response.create"])
        }
    }
}
