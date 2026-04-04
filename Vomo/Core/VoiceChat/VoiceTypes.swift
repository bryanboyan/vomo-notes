import Foundation

/// Connection state for the voice chat
enum VoiceChatState: Equatable {
    case disconnected
    case connecting
    case connected
    case listening        // VAD detected user speech
    case responding       // Grok is generating audio
    case error(String)

    static func == (lhs: VoiceChatState, rhs: VoiceChatState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected),
             (.listening, .listening),
             (.responding, .responding):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Input mode for voice sessions
enum VoiceInputMode: String {
    case interactive  // Server VAD, always listening
    case ptt          // Push-to-talk, manual control
}
