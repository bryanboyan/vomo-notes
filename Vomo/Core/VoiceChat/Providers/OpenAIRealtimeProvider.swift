import Foundation

/// OpenAI realtime voice provider.
/// Uses Bearer token in Authorization header.
final class OpenAIRealtimeProvider: OpenAICompatibleRealtimeProvider {

    override func wsURL(apiKey: String) -> URL? {
        URL(string: "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview")
    }

    override func configureAuth(request: inout URLRequest, apiKey: String) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    override class func fetchVoices(apiKey: String) async throws -> [String] {
        // OpenAI has no voice list endpoint — return hardcoded
        return ["alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
    }
}
