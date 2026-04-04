import SwiftUI

/// ViewModifier wrapping the Grok API key alert
struct VoiceAPIKeyPrompt: ViewModifier {
    @Binding var isPresented: Bool
    var onSaved: () -> Void
    @State private var apiKeyInput = ""

    func body(content: Content) -> some View {
        content
            .alert("Grok API Key", isPresented: $isPresented) {
                SecureField("xai-...", text: $apiKeyInput)
                Button("Save") {
                    if !apiKeyInput.isEmpty {
                        _ = APIKeychain.save(vendor: VoiceSettings.shared.realtimeVendor.rawValue, key: apiKeyInput)
                        apiKeyInput = ""
                        onSaved()
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Enter your xAI API key to use voice features.")
            }
    }
}

extension View {
    func voiceAPIKeyPrompt(isPresented: Binding<Bool>, onSaved: @escaping () -> Void) -> some View {
        modifier(VoiceAPIKeyPrompt(isPresented: isPresented, onSaved: onSaved))
    }
}
