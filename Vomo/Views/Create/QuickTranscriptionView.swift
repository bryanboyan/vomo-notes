import SwiftUI
import Speech

/// Lightweight speech-to-text recording triggered by long-pressing Create.
/// Saves raw transcription to Assets/Transcriptions/ as .md with frontmatter.
struct QuickTranscriptionView: View {
    @Environment(VaultManager.self) var vault
    @Environment(\.dismiss) var dismiss

    @State private var sttProvider: STTProvider?

    // Convenience accessors that forward to the active STT provider
    private var transcribedText: String {
        sttProvider?.text ?? ""
    }

    private var transcriptionIsActive: Bool {
        sttProvider?.isActive ?? false
    }

    private var transcriptionError: String? {
        sttProvider?.errorMessage
    }

    @State private var elapsedSeconds = 0
    @State private var startTime = Date()
    @State private var editableText = ""
    @State private var isEditing = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Nav bar
            HStack {
                Button {
                    stopTranscription()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }

                Spacer()

                Text(isEditing ? "Edit Transcription" : "Quick Transcription")
                    .font(.headline)

                Spacer()

                if isEditing {
                    Button {
                        save()
                    } label: {
                        Text("Save")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.obsidianPurple,
                                in: Capsule()
                            )
                    }
                    .disabled(editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button {
                        enterEditMode()
                    } label: {
                        Text("Done")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                transcribedText.isEmpty ? Color.gray : Color.obsidianPurple,
                                in: Capsule()
                            )
                    }
                    .disabled(transcribedText.isEmpty)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            // Transcript area
            if isEditing {
                TextEditor(text: $editableText)
                    .font(.body)
                    .padding()
                    .focused($isTextFieldFocused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        if transcribedText.isEmpty {
                            VStack(spacing: 16) {
                                Spacer().frame(height: 80)

                                if transcriptionIsActive {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 48))
                                        .foregroundStyle(.tertiary)
                                        .symbolEffect(.variableColor.iterative, isActive: true)
                                    Text("Listening...")
                                        .font(.subheadline)
                                        .foregroundStyle(.tertiary)
                                } else if let error = transcriptionError {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.system(size: 48))
                                        .foregroundStyle(.orange)
                                    Text(error)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                } else {
                                    ProgressView()
                                    Text("Starting...")
                                        .font(.subheadline)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text(transcribedText)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .textSelection(.enabled)

                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }
                    .onChange(of: transcribedText) {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Divider()

            // Bottom bar
            HStack(spacing: 12) {
                if transcriptionIsActive {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                    Text(formattedTime)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if !isEditing {
                    Circle()
                        .fill(.gray)
                        .frame(width: 10, height: 10)
                    Text("Stopped")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Editing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !transcribedText.isEmpty || !editableText.isEmpty {
                    let wordCount = isEditing ?
                        editableText.split(separator: " ").count :
                        transcribedText.split(separator: " ").count
                    Text("\(wordCount) words")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .background(Color(.systemBackground))
        .onAppear {
            startTime = Date()
            startTranscription()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if transcriptionIsActive {
                elapsedSeconds = Int(Date().timeIntervalSince(startTime))
            }
        }
        .onDisappear {
            stopTranscription()
        }
    }

    private var formattedTime: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func startTranscription() {
        let vendor = VoiceSettings.shared.sttVendor

        guard let provider = VoiceProviderFactory.makeSTT(vendor: vendor) else {
            // Fallback to Apple if selected vendor requires a key but none is saved
            let fallback = VoiceProviderFactory.makeSTT(vendor: .apple)
            sttProvider = fallback
            if let apple = fallback as? AppleSTTProvider {
                Task {
                    let ok = await apple.requestAuthorization()
                    if ok { apple.start() }
                }
            }
            return
        }

        sttProvider = provider

        if let apple = provider as? AppleSTTProvider {
            if let sttInstructions = VomoConfig.sttInstructions(vaultURL: vault.vaultURL) {
                apple.sttInstructions = sttInstructions
                let terms = sttInstructions.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                apple.contextualStrings = terms
            }
            Task {
                let ok = await apple.requestAuthorization()
                if ok { apple.start() }
            }
        } else {
            provider.start()
        }
    }

    private func stopTranscription() {
        sttProvider?.stop()
    }

    private func enterEditMode() {
        stopTranscription()
        editableText = transcribedText
        isEditing = true
        // Focus the text editor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isTextFieldFocused = true
        }
    }

    private func save() {
        let finalText = isEditing ? editableText : transcribedText

        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dismiss()
            return
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HH-mm"
        let filename = fmt.string(from: startTime) + ".md"

        let isoDate = ISO8601DateFormatter().string(from: startTime)
        let content = """
        ---
        type: quick
        saved: false
        title: ""
        date: \(isoDate)
        duration: \(elapsedSeconds)
        ---

        \(finalText)
        """

        let folder = SettingsManager.shared.transcriptionFolder
        if SettingsManager.shared.saveTranscriptions {
            _ = vault.createFile(name: filename, folderPath: folder, content: content)
        }
        dismiss()
    }
}
