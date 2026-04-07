import Foundation

/// Single source of truth for all app preferences.
/// Wraps UserDefaults for persistence. Sections: voice, paths, display.
@Observable
final class SettingsManager {
    static let shared = SettingsManager()

    // MARK: - Paths

    /// Folder for saving transcriptions (quick STT and voice creation)
    var transcriptionFolder: String {
        didSet { UserDefaults.standard.set(transcriptionFolder, forKey: Keys.transcriptionFolder) }
    }

    /// Default folder for new notes
    var creationDefaultFolder: String {
        didSet { UserDefaults.standard.set(creationDefaultFolder, forKey: Keys.creationDefaultFolder) }
    }

    /// Daily notes folder name
    var dailyNotesFolder: String {
        didSet { UserDefaults.standard.set(dailyNotesFolder, forKey: Keys.dailyNotesFolder) }
    }

    /// Whether to auto-save transcriptions
    var saveTranscriptions: Bool {
        didSet { UserDefaults.standard.set(saveTranscriptions, forKey: Keys.saveTranscriptions) }
    }

    // MARK: - Voice Search Scope

    var voiceSearchIncludeFolders: [String] {
        didSet { UserDefaults.standard.set(voiceSearchIncludeFolders, forKey: Keys.voiceSearchIncludeFolders) }
    }
    var voiceSearchExcludeFolders: [String] {
        didSet { UserDefaults.standard.set(voiceSearchExcludeFolders, forKey: Keys.voiceSearchExcludeFolders) }
    }

    func isInVoiceSearchScope(folderPath: String) -> Bool {
        if !voiceSearchIncludeFolders.isEmpty {
            return voiceSearchIncludeFolders.contains {
                folderPath == $0 || folderPath.hasPrefix($0 + "/")
            }
        }
        if !voiceSearchExcludeFolders.isEmpty {
            return !voiceSearchExcludeFolders.contains {
                folderPath == $0 || folderPath.hasPrefix($0 + "/")
            }
        }
        return true
    }

    var voiceSearchScopeSummary: String {
        if !voiceSearchIncludeFolders.isEmpty { return "\(voiceSearchIncludeFolders.count) included" }
        if !voiceSearchExcludeFolders.isEmpty { return "\(voiceSearchExcludeFolders.count) excluded" }
        return "All folders"
    }

    // MARK: - Init + Migration

    private init() {
        let defaults = UserDefaults.standard

        // Migrate old keys
        if !defaults.bool(forKey: Keys.migrated) {
            Self.migrateOldKeys(defaults)
        }

        transcriptionFolder = defaults.string(forKey: Keys.transcriptionFolder) ?? "Assets/Transcriptions"
        creationDefaultFolder = defaults.string(forKey: Keys.creationDefaultFolder) ?? ""
        dailyNotesFolder = defaults.string(forKey: Keys.dailyNotesFolder) ?? "Daily Notes"
        saveTranscriptions = defaults.object(forKey: Keys.saveTranscriptions) == nil
            ? true
            : defaults.bool(forKey: Keys.saveTranscriptions)
        voiceSearchIncludeFolders = defaults.stringArray(forKey: Keys.voiceSearchIncludeFolders) ?? []
        voiceSearchExcludeFolders = defaults.stringArray(forKey: Keys.voiceSearchExcludeFolders) ?? []
    }

    private static func migrateOldKeys(_ defaults: UserDefaults) {
        // Migrate old creation.defaultFolder key
        if let oldFolder = defaults.string(forKey: "creation.defaultFolder") {
            defaults.set(oldFolder, forKey: Keys.creationDefaultFolder)
        }
        defaults.set(true, forKey: Keys.migrated)
    }

    private enum Keys {
        static let transcriptionFolder = "settings.transcriptionFolder"
        static let creationDefaultFolder = "settings.creationDefaultFolder"
        static let dailyNotesFolder = "settings.dailyNotesFolder"
        static let saveTranscriptions = "settings.saveTranscriptions"
        static let migrated = "settings.migrated"
        static let voiceSearchIncludeFolders = "settings.voiceSearch.includeFolders"
        static let voiceSearchExcludeFolders = "settings.voiceSearch.excludeFolders"
    }
}
