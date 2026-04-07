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

    var textModelVendor: TextModelVendor {
        didSet { UserDefaults.standard.set(textModelVendor.rawValue, forKey: Keys.textModelVendor) }
    }

    // MARK: - Cached Voices (in-memory only)

    var cachedVoices: [String] = []
    var isLoadingVoices = false

    var autoLoadNoteContent: Bool {
        didSet { UserDefaults.standard.set(autoLoadNoteContent, forKey: Keys.autoLoadNoteContent) }
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

        if let raw = defaults.string(forKey: Keys.textModelVendor),
           let vendor = TextModelVendor(rawValue: raw) {
            textModelVendor = vendor
        } else {
            textModelVendor = .xai
        }

        autoLoadNoteContent = defaults.object(forKey: Keys.autoLoadNoteContent) as? Bool ?? true
    }

    private static func migrateOldKeys(_ defaults: UserDefaults) {
        if let oldVoice = defaults.string(forKey: "voiceSearch.selectedVoice") {
            defaults.set(oldVoice, forKey: "voice.selectedVoice.xai")
        }
        if let oldVoice = defaults.string(forKey: "voice.selectedVoice") {
            defaults.set(oldVoice, forKey: "voice.selectedVoice.xai")
        }
        defaults.set(true, forKey: Keys.migrated)
    }

    private enum Keys {
        static let realtimeVendor = "voice.realtimeVendor"
        static let sttVendor = "voice.sttVendor"
        static let textModelVendor = "voice.textModelVendor"
        static let autoLoadNoteContent = "voice.autoLoadNoteContent"
        static let migrated = "voice.settingsMigrated"
    }
}
