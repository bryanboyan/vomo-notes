import Foundation
#if canImport(Speech)
import Speech

/// Wraps SpeechTranscriber to conform to STTProvider protocol.
/// Free on-device transcription using Apple's Speech framework.
@Observable
final class AppleSTTProvider: STTProvider {
    private let transcriber = SpeechTranscriber()

    var text: String { transcriber.text }
    var isActive: Bool { transcriber.isActive }
    var errorMessage: String? { transcriber.errorMessage }

    /// Additional context strings for recognition accuracy
    var contextualStrings: [String] {
        get { transcriber.contextualStrings }
        set { transcriber.contextualStrings = newValue }
    }

    /// STT instructions from vault config
    var sttInstructions: String? {
        get { transcriber.sttInstructions }
        set { transcriber.sttInstructions = newValue }
    }

    func requestAuthorization() async -> Bool {
        await transcriber.requestAuthorization()
    }

    func start() {
        transcriber.start()
    }

    func stop() {
        transcriber.stop()
    }
}
#endif
