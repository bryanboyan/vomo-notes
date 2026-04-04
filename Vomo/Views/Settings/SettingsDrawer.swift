import SwiftUI

/// Left-sliding drawer overlay for app settings
struct SettingsDrawer: View {
    @Binding var isPresented: Bool
    @Environment(VaultManager.self) var vault
    let settings = SettingsManager.shared
    let voiceSettings = VoiceSettings.shared

    // Local editing state
    @State private var selectedVoice: String
    @State private var searchCustomRules: String
    @State private var creationCustomPrompt: String
    @State private var transcriptionFolder: String
    @State private var creationDefaultFolder: String
    @State private var dailyNotesFolder: String
    @State private var saveTranscriptions: Bool
    @State private var showVaultPicker = false
    @State private var showEmbeddingsPicker = false

    // Provider state
    @State private var realtimeVendor: VoiceVendor
    @State private var sttVendor: STTVendor
    @State private var apiKeyInputs: [String: String] = [:]
    @State private var availableVoices: [String] = []
    @State private var isLoadingVoices = false

    init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
        let vs = VoiceSettings.shared
        let sm = SettingsManager.shared
        _selectedVoice = State(initialValue: vs.selectedVoice)
        _searchCustomRules = State(initialValue: vs.searchCustomRules)
        _creationCustomPrompt = State(initialValue: vs.creationCustomPrompt)
        _transcriptionFolder = State(initialValue: sm.transcriptionFolder)
        _creationDefaultFolder = State(initialValue: sm.creationDefaultFolder)
        _dailyNotesFolder = State(initialValue: sm.dailyNotesFolder)
        _saveTranscriptions = State(initialValue: sm.saveTranscriptions)
        _realtimeVendor = State(initialValue: vs.realtimeVendor)
        _sttVendor = State(initialValue: vs.sttVendor)
    }

    @State private var dragOffset: CGFloat = 0
    @State private var appeared = false

    private enum DragAxis { case undecided, horizontal, vertical }
    @State private var dragAxis: DragAxis = .undecided

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                if dragAxis == .undecided {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    // Lock to vertical early: any meaningful vertical movement
                    // before a strong horizontal signal locks out dismiss.
                    if dy > 10 && dx < dy {
                        dragAxis = .vertical
                    } else if dx > 20 && dx > dy * 2 {
                        dragAxis = .horizontal
                    }
                }
                if dragAxis == .horizontal && value.translation.width < 0 {
                    dragOffset = value.translation.width
                }
            }
            .onEnded { value in
                defer { dragAxis = .undecided }
                guard dragAxis == .horizontal else {
                    dragOffset = 0
                    return
                }
                if value.translation.width < -60 || value.predictedEndTranslation.width < -150 {
                    closeDrawer()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private let drawerWidth = UIScreen.main.bounds.width * 0.82

    var body: some View {
        let progress = appeared ? max(0, 1 + Double(dragOffset) / 200) : 0.0

        ZStack(alignment: .leading) {
            // Dimmed backdrop
            Color.black.opacity(0.3 * progress)
                .ignoresSafeArea()
                .onTapGesture { closeDrawer() }
                .gesture(dismissDrag)

            // Drawer content
            NavigationStack {
                List {
                    providersSection
                    transcribeSection
                    promptsSection
                    pathsSection
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { closeDrawer() }
                    }
                }
            }
            .frame(width: drawerWidth)
            .offset(x: appeared ? min(0, dragOffset) : -drawerWidth)
            .simultaneousGesture(dismissDrag)
        }
        .allowsHitTesting(appeared)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) {
                appeared = true
            }
            loadVoicesForVendor()
        }
        .sheet(isPresented: $showVaultPicker) {
            DocumentPicker { url in
                vault.resetVault()
                vault.saveBookmark(for: url)
            }
        }
        .sheet(isPresented: $showEmbeddingsPicker) {
            DocumentPicker { url in
                vault.saveEmbeddingsBookmark(for: url)
            }
        }
    }

    // MARK: - Sections

    private var providersSection: some View {
        Section("Providers") {
            // Realtime Voice vendor picker
            Picker("Realtime Voice", selection: $realtimeVendor) {
                ForEach(VoiceVendor.allCases, id: \.self) { vendor in
                    Text(vendor.displayName).tag(vendor)
                }
            }
            .font(.subheadline)
            .onChange(of: realtimeVendor) {
                voiceSettings.realtimeVendor = realtimeVendor
                loadVoicesForVendor()
            }

            // API Key for realtime vendor
            apiKeyRow(vendor: realtimeVendor.rawValue, label: "\(realtimeVendor.displayName) API Key")

            // Voice picker (dynamic)
            if APIKeychain.hasKey(vendor: realtimeVendor.rawValue) {
                voicePickerRow
            }

            Divider()

            // STT vendor picker
            Picker("Transcription (STT)", selection: $sttVendor) {
                ForEach(STTVendor.allCases, id: \.self) { vendor in
                    Text(vendor.displayName).tag(vendor)
                }
            }
            .font(.subheadline)
            .onChange(of: sttVendor) {
                voiceSettings.sttVendor = sttVendor
            }

            // API Key for STT vendor (hidden for Apple)
            if sttVendor.requiresAPIKey {
                let sttKeyVendor: String = {
                    switch sttVendor {
                    case .apple: return ""
                    case .openai: return VoiceVendor.openai.rawValue
                    case .deepgram: return VoiceVendor.deepgram.rawValue
                    }
                }()

                if sttKeyVendor != realtimeVendor.rawValue {
                    apiKeyRow(vendor: sttKeyVendor, label: "\(sttVendor.displayName) API Key")
                } else {
                    HStack {
                        Text("\(sttVendor.displayName) API Key")
                            .font(.subheadline)
                        Spacer()
                        Text("Shared with Realtime")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func apiKeyRow(vendor: String, label: String) -> some View {
        if APIKeychain.hasKey(vendor: vendor) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text("Configured")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Button("Update Key", role: .destructive) {
                APIKeychain.delete(vendor: vendor)
                apiKeyInputs[vendor] = ""
            }
            .font(.subheadline)
        } else {
            SecureField("API Key", text: Binding(
                get: { apiKeyInputs[vendor] ?? "" },
                set: { apiKeyInputs[vendor] = $0 }
            ))
            .font(.subheadline)
            Button("Save") {
                if let input = apiKeyInputs[vendor], !input.isEmpty {
                    _ = APIKeychain.save(vendor: vendor, key: input)
                    apiKeyInputs[vendor] = ""
                    if vendor == realtimeVendor.rawValue {
                        loadVoicesForVendor()
                    }
                }
            }
            .font(.subheadline)
            .disabled(apiKeyInputs[vendor]?.isEmpty ?? true)
        }
    }

    private var voicePickerRow: some View {
        Group {
            if isLoadingVoices {
                HStack {
                    Text("Voice")
                        .font(.subheadline)
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                }
            } else {
                Picker("Voice", selection: $selectedVoice) {
                    let voices = availableVoices.isEmpty
                        ? (VoiceSettings.defaultVoices[realtimeVendor] ?? [])
                        : availableVoices
                    ForEach(voices, id: \.self) { voice in
                        Text(voice).tag(voice)
                    }
                }
                .font(.subheadline)
                .onChange(of: selectedVoice) {
                    voiceSettings.selectedVoice = selectedVoice
                }
            }
        }
    }

    private var transcribeSection: some View {
        Section {
            Toggle("Auto-save Transcriptions", isOn: $saveTranscriptions)
                .font(.subheadline)
                .onChange(of: saveTranscriptions) {
                    settings.saveTranscriptions = saveTranscriptions
                }

            HStack {
                Text("Transcription Folder")
                    .font(.subheadline)
                Spacer()
                TextField("Assets/Transcriptions", text: $transcriptionFolder)
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .onChange(of: transcriptionFolder) {
                        settings.transcriptionFolder = transcriptionFolder
                    }
            }
        } header: {
            Text("Transcribe")
        }
    }

    private var promptsSection: some View {
        Section("Prompts") {
            DisclosureGroup("Search Custom Rules") {
                TextEditor(text: $searchCustomRules)
                    .font(.caption)
                    .frame(minHeight: 80)
                    .onChange(of: searchCustomRules) {
                        voiceSettings.searchCustomRules = searchCustomRules
                    }
            }

            DisclosureGroup("Creation Custom Prompt") {
                TextEditor(text: $creationCustomPrompt)
                    .font(.caption)
                    .frame(minHeight: 80)
                    .onChange(of: creationCustomPrompt) {
                        voiceSettings.creationCustomPrompt = creationCustomPrompt
                    }
            }
        }
    }

    private var pathsSection: some View {
        Section {
            HStack {
                Text("Default Note Folder")
                    .font(.subheadline)
                Spacer()
                TextField("(Vault Root)", text: $creationDefaultFolder)
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .onChange(of: creationDefaultFolder) {
                        settings.creationDefaultFolder = creationDefaultFolder
                    }
            }

            HStack {
                Text("Daily Notes Folder")
                    .font(.subheadline)
                Spacer()
                TextField("Daily Notes", text: $dailyNotesFolder)
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .onChange(of: dailyNotesFolder) {
                        settings.dailyNotesFolder = dailyNotesFolder
                    }
            }

            // Vault
            HStack {
                Text("Current Vault")
                    .font(.subheadline)
                Spacer()
                Text(vault.vaultDisplayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button("Change Vault") {
                showVaultPicker = true
            }
            .font(.subheadline)

            // Embeddings
            HStack {
                Text("Embeddings")
                    .font(.subheadline)
                Spacer()
                Text(vault.hasEmbeddings ? vault.embeddingsDisplayPath : "None")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button("Custom Embeddings Folder") {
                showEmbeddingsPicker = true
            }
            .font(.subheadline)

            if vault.embeddingsURL != nil {
                Button("Reset Embeddings to Default", role: .destructive) {
                    vault.clearEmbeddingsBookmark()
                }
                .font(.subheadline)
            }
        } header: {
            Text("Paths")
        }
    }

    // MARK: - Actions

    private func loadVoicesForVendor() {
        let vendor = realtimeVendor
        guard let apiKey = APIKeychain.load(vendor: vendor.rawValue) else {
            availableVoices = VoiceSettings.defaultVoices[vendor] ?? []
            selectedVoice = voiceSettings.savedVoice(for: vendor)
            return
        }

        isLoadingVoices = true
        Task {
            let voices = await VoiceProviderFactory.fetchVoices(vendor: vendor, apiKey: apiKey)
            await MainActor.run {
                availableVoices = voices
                voiceSettings.cachedVoices = voices
                selectedVoice = voiceSettings.savedVoice(for: vendor)
                isLoadingVoices = false
            }
        }
    }

    private func closeDrawer() {
        withAnimation(.easeInOut(duration: 0.25)) {
            appeared = false
            dragOffset = 0
        } completion: {
            isPresented = false
        }
    }
}
