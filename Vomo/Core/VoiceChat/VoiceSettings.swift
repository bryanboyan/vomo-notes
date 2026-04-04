import Foundation

/// Centralized UserDefaults for all voice-related settings.
@Observable
final class VoiceSettings {
    static let shared = VoiceSettings()

    // MARK: - Voice Selection (per-vendor)

    var selectedVoice: String {
        get {
            UserDefaults.standard.string(forKey: "voice.selectedVoice.\(realtimeVendor.rawValue)")
                ?? Self.defaultVoice(for: realtimeVendor)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "voice.selectedVoice.\(realtimeVendor.rawValue)")
        }
    }

    func savedVoice(for vendor: VoiceVendor) -> String {
        UserDefaults.standard.string(forKey: "voice.selectedVoice.\(vendor.rawValue)")
            ?? Self.defaultVoice(for: vendor)
    }

    static func defaultVoice(for vendor: VoiceVendor) -> String {
        switch vendor {
        case .xai: "Ara"
        case .openai: "alloy"
        case .deepgram: "aura-2-helena-en"
        }
    }

    // MARK: - Vendor Selection

    var realtimeVendor: VoiceVendor {
        didSet { UserDefaults.standard.set(realtimeVendor.rawValue, forKey: Keys.realtimeVendor) }
    }

    var sttVendor: STTVendor {
        didSet { UserDefaults.standard.set(sttVendor.rawValue, forKey: Keys.sttVendor) }
    }

    // MARK: - Cached Voices (in-memory only)

    var cachedVoices: [String] = []
    var isLoadingVoices = false

    // MARK: - Custom Rules

    var searchCustomRules: String {
        didSet { UserDefaults.standard.set(searchCustomRules, forKey: Keys.searchCustomRules) }
    }

    var creationCustomPrompt: String {
        didSet { UserDefaults.standard.set(creationCustomPrompt, forKey: Keys.creationCustomPrompt) }
    }

    var autoLoadNoteContent: Bool {
        didSet { UserDefaults.standard.set(autoLoadNoteContent, forKey: Keys.autoLoadNoteContent) }
    }

    // MARK: - Server Proxy (kept but not exposed in UI)

    var useServerRealtime: Bool {
        didSet { UserDefaults.standard.set(useServerRealtime, forKey: Keys.useServerRealtime) }
    }

    var useServerSTT: Bool {
        didSet { UserDefaults.standard.set(useServerSTT, forKey: Keys.useServerSTT) }
    }

    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Keys.serverURL) }
    }

    // MARK: - Constants

    static let defaultVoices: [VoiceVendor: [String]] = [
        .xai: ["Ara", "Eve", "Rex", "Sal", "Leo"],
        .openai: ["alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"],
        .deepgram: ["aura-2-helena-en", "aura-2-asteria-en", "aura-2-luna-en", "aura-2-athena-en", "aura-2-orion-en"]
    ]

    static var voices: [String] {
        let vendor = shared.realtimeVendor
        return shared.cachedVoices.isEmpty
            ? (defaultVoices[vendor] ?? [])
            : shared.cachedVoices
    }

    // MARK: - Init + Migration

    private init() {
        let defaults = UserDefaults.standard

        if !defaults.bool(forKey: Keys.migrated) {
            Self.migrateOldKeys(defaults)
        }

        if let raw = defaults.string(forKey: Keys.realtimeVendor),
           let vendor = VoiceVendor(rawValue: raw) {
            realtimeVendor = vendor
        } else {
            realtimeVendor = .xai
        }

        if let raw = defaults.string(forKey: Keys.sttVendor),
           let vendor = STTVendor(rawValue: raw) {
            sttVendor = vendor
        } else {
            sttVendor = .apple
        }

        searchCustomRules = defaults.string(forKey: Keys.searchCustomRules) ?? ""
        creationCustomPrompt = defaults.string(forKey: Keys.creationCustomPrompt) ?? ""
        autoLoadNoteContent = defaults.object(forKey: Keys.autoLoadNoteContent) as? Bool ?? true
        useServerRealtime = defaults.bool(forKey: Keys.useServerRealtime)
        useServerSTT = defaults.bool(forKey: Keys.useServerSTT)
        serverURL = defaults.string(forKey: Keys.serverURL) ?? "vomo-server.ngrok-free.app"
    }

    private static func migrateOldKeys(_ defaults: UserDefaults) {
        if let oldVoice = defaults.string(forKey: "voiceSearch.selectedVoice") {
            defaults.set(oldVoice, forKey: "voice.selectedVoice.xai")
        }
        if let oldVoice = defaults.string(forKey: "voice.selectedVoice") {
            defaults.set(oldVoice, forKey: "voice.selectedVoice.xai")
        }
        if let oldRules = defaults.string(forKey: "voiceSearch.customRules") {
            defaults.set(oldRules, forKey: Keys.searchCustomRules)
        }
        if let oldPrompt = defaults.string(forKey: "creation.voiceSystemPrompt") {
            defaults.set(oldPrompt, forKey: Keys.creationCustomPrompt)
        }
        defaults.set(true, forKey: Keys.migrated)
    }

    private enum Keys {
        static let realtimeVendor = "voice.realtimeVendor"
        static let sttVendor = "voice.sttVendor"
        static let searchCustomRules = "voice.searchCustomRules"
        static let creationCustomPrompt = "voice.creationCustomPrompt"
        static let autoLoadNoteContent = "voice.autoLoadNoteContent"
        static let migrated = "voice.settingsMigrated"
        static let useServerRealtime = "voice.useServerRealtime"
        static let useServerSTT = "voice.useServerSTT"
        static let serverURL = "voice.serverURL"
    }
}
