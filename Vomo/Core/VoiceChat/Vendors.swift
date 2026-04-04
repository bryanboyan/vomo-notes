import Foundation

/// Vendors available for realtime voice conversation
enum VoiceVendor: String, CaseIterable, Codable {
    case xai
    case openai
    case deepgram

    var displayName: String {
        switch self {
        case .xai: "xAI (Grok)"
        case .openai: "OpenAI"
        case .deepgram: "Deepgram"
        }
    }
}

/// Vendors available for speech-to-text transcription
enum STTVendor: String, CaseIterable, Codable {
    case apple
    case openai
    case deepgram

    var displayName: String {
        switch self {
        case .apple: "Apple (On-Device)"
        case .openai: "OpenAI (Whisper)"
        case .deepgram: "Deepgram"
        }
    }

    /// Whether this vendor requires an API key
    var requiresAPIKey: Bool {
        self != .apple
    }
}
