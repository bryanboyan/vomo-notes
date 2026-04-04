import SwiftUI

/// Voice selection picker — shared across all voice UIs
struct VoicePickerMenu: View {
    @Binding var selectedVoice: String

    var body: some View {
        Menu("Voice") {
            ForEach(VoiceSettings.voices, id: \.self) { voice in
                Button {
                    selectedVoice = voice
                    VoiceSettings.shared.selectedVoice = voice
                } label: {
                    HStack {
                        Text(voice)
                        if voice == selectedVoice {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }
}
