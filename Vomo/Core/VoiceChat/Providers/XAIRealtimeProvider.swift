import Foundation

/// xAI (Grok) realtime voice provider.
/// Uses Sec-WebSocket-Protocol header for authentication.
final class XAIRealtimeProvider: OpenAICompatibleRealtimeProvider {

    override func wsURL(apiKey: String) -> URL? {
        URL(string: "wss://api.x.ai/v1/realtime")
    }

    override func configureAuth(request: inout URLRequest, apiKey: String) {
        request.setValue("xai-client-secret.\(apiKey)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
    }

    override class func fetchVoices(apiKey: String) async throws -> [String] {
        // xAI has no voice list endpoint — return hardcoded
        return ["Ara", "Eve", "Rex", "Sal", "Leo"]
    }
}
