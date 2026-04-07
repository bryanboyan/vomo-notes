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

/// Vendors available for text model API calls (summarization, save)
enum TextModelVendor: String, CaseIterable, Codable, Identifiable {
    case xai
    case openai
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .xai: "xAI"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        }
    }

    /// Keychain key — shared with VoiceVendor where vendor matches
    var keychainKey: String { rawValue }

    var endpoint: String {
        switch self {
        case .xai: "https://api.x.ai/v1/chat/completions"
        case .openai: "https://api.openai.com/v1/chat/completions"
        case .anthropic: "https://api.anthropic.com/v1/messages"
        }
    }

    var model: String {
        switch self {
        case .xai: "grok-3-fast"
        case .openai: "gpt-4o"
        case .anthropic: "claude-sonnet-4-6-20250514"
        }
    }
}
