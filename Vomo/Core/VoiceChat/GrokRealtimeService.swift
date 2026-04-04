import Foundation

/// Configuration for routing through a proxy server instead of direct API
struct ServerConfig {
    let url: String
    let token: String

    static func currentIfEnabled() -> ServerConfig? {
        guard VoiceSettings.shared.useServerRealtime, let token = ServerKeychain.load() else { return nil }
        return ServerConfig(url: VoiceSettings.shared.serverURL, token: token)
    }
}

/// Legacy alias — use XAIRealtimeProvider directly for new code.
typealias GrokRealtimeService = XAIRealtimeProvider
