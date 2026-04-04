import Foundation

/// Factory for creating voice and STT provider instances based on vendor selection.
enum VoiceProviderFactory {

    /// Create a realtime voice provider for the given vendor.
    static func makeRealtime(vendor: VoiceVendor) -> RealtimeVoiceProvider {
        switch vendor {
        case .xai:
            return XAIRealtimeProvider()
        case .openai:
            return OpenAIRealtimeProvider()
        case .deepgram:
            return DeepgramRealtimeProvider()
        }
    }

    /// Create an STT provider for the given vendor.
    /// Returns nil if the vendor requires an API key and none is saved.
    static func makeSTT(vendor: STTVendor) -> STTProvider? {
        switch vendor {
        case .apple:
            #if canImport(Speech)
            return AppleSTTProvider()
            #else
            return nil
            #endif
        case .openai:
            guard let key = APIKeychain.load(vendor: VoiceVendor.openai.rawValue) else { return nil }
            return OpenAISTTProvider(apiKey: key)
        case .deepgram:
            guard let key = APIKeychain.load(vendor: VoiceVendor.deepgram.rawValue) else { return nil }
            return DeepgramSTTProvider(apiKey: key)
        }
    }

    /// Fetch available voices for a vendor.
    static func fetchVoices(vendor: VoiceVendor, apiKey: String) async -> [String] {
        do {
            switch vendor {
            case .xai:
                return try await XAIRealtimeProvider.fetchVoices(apiKey: apiKey)
            case .openai:
                return try await OpenAIRealtimeProvider.fetchVoices(apiKey: apiKey)
            case .deepgram:
                return try await DeepgramRealtimeProvider.fetchVoices(apiKey: apiKey)
            }
        } catch {
            DiagnosticLogger.shared.warning("VoiceFactory", "Failed to fetch voices for \(vendor): \(error.localizedDescription)")
            return VoiceSettings.defaultVoices[vendor] ?? []
        }
    }
}
