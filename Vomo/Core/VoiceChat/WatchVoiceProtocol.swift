import Foundation

// MARK: - WatchConnectivity Message Keys

/// Message types exchanged between watch and phone for voice proxy
enum WCVoiceMessageType {
    /// Control messages sent via sendMessage (dictionary-based)
    static let voiceConnect = "voiceConnect"
    static let voiceDisconnect = "voiceDisconnect"
    static let voiceStateUpdate = "voiceStateUpdate"
    static let voicePTTStart = "voicePTTStart"
    static let voicePTTStop = "voicePTTStop"
    static let voiceModeSwitch = "voiceModeSwitch"
    static let voiceTranscriptUpdate = "voiceTranscriptUpdate"

    /// Binary messages sent via sendMessageData
    /// First byte = tag, rest = payload
    static let audioFromWatch: UInt8 = 0x01   // Watch mic PCM → phone
    static let audioFromPhone: UInt8 = 0x02   // Phone xAI response PCM → watch
}

/// Voice state serialized for WatchConnectivity transfer
enum WCVoiceState: String, Codable {
    case disconnected
    case connecting
    case connected
    case listening
    case responding
    case error

    init(from state: VoiceChatState) {
        switch state {
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .listening: self = .listening
        case .responding: self = .responding
        case .error: self = .error
        }
    }

    func toVoiceChatState(errorMessage: String? = nil) -> VoiceChatState {
        switch self {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        case .listening: return .listening
        case .responding: return .responding
        case .error: return .error(errorMessage ?? "Unknown error")
        }
    }
}

/// Configuration sent from watch to phone to start a voice session
struct WatchSessionConfig: Codable {
    let recordingMode: String  // RecordingMode.rawValue
    let inputMode: String      // "interactive" or "ptt"
}
