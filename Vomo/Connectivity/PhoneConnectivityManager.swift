import Foundation
import WatchConnectivity

/// Manages WatchConnectivity on the iPhone side.
/// Receives transcripts from Apple Watch and saves them to the vault.
/// Also bridges voice sessions — watch sends mic audio, phone runs xAI WebSocket.
@Observable
final class PhoneConnectivityManager: NSObject {
    static let shared = PhoneConnectivityManager()

    private(set) var isWatchReachable = false
    private let session = WCSession.default

    /// Set by the app to enable vault saving and voice tool execution
    var vaultManager: VaultManager? {
        didSet { voiceBridge.vaultManager = vaultManager }
    }

    /// Set by the app to enable dataview-powered search in voice tools
    var dataviewEngine: DataviewEngine? {
        didSet { voiceBridge.dataviewEngine = dataviewEngine }
    }

    /// Voice bridge for watch proxy sessions
    let voiceBridge = WatchVoiceBridge()

    override init() {
        super.init()
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
    }

    /// Push the API key to the watch (call after user saves key on phone)
    func syncApiKeyToWatch() {
        guard let key = APIKeychain.load(vendor: VoiceSettings.shared.realtimeVendor.rawValue) else { return }
        do {
            try session.updateApplicationContext(["apiKey": key])
        } catch {
            // Fall back to message if context update fails
            if session.isReachable {
                session.sendMessage(["apiKey": key], replyHandler: nil, errorHandler: nil)
            }
        }
    }

    /// Push current folder list to the watch
    func syncFoldersToWatch() {
        guard let vault = vaultManager else { return }
        let folderPaths = Array(Set(vault.files.map(\.folderPath)).filter { !$0.isEmpty }).sorted()
        do {
            try session.updateApplicationContext(["folderList": folderPaths])
        } catch {
            if session.isReachable {
                session.sendMessage(["folderList": folderPaths], replyHandler: nil, errorHandler: nil)
            }
        }
    }
}

// MARK: - WCSessionDelegate

extension PhoneConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            isWatchReachable = session.isReachable
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            isWatchReachable = session.isReachable
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let type = message["type"] as? String else {
            replyHandler([:])
            return
        }

        switch type {
        case "requestApiKey":
            let key = APIKeychain.load(vendor: VoiceSettings.shared.realtimeVendor.rawValue) ?? ""
            replyHandler(["key": key])

        case "requestFolders":
            let folders = vaultManager.map { vault in
                Array(Set(vault.files.map(\.folderPath)).filter { !$0.isEmpty }).sorted()
            } ?? []
            replyHandler(["folders": folders])

        case "saveTranscript":
            let success = handleSaveTranscript(message)
            replyHandler(["success": success])

        case WCVoiceMessageType.voiceConnect:
            handleVoiceConnect(message)
            replyHandler(["ok": true])

        case WCVoiceMessageType.voiceDisconnect:
            voiceBridge.stop()
            replyHandler(["ok": true])

        case WCVoiceMessageType.voicePTTStart:
            voiceBridge.handlePTTStart()
            replyHandler(["ok": true])

        case WCVoiceMessageType.voicePTTStop:
            voiceBridge.handlePTTStop()
            replyHandler(["ok": true])

        case WCVoiceMessageType.voiceModeSwitch:
            if let mode = message["inputMode"] as? String {
                voiceBridge.handleModeSwitch(inputMode: mode)
            }
            replyHandler(["ok": true])

        default:
            replyHandler([:])
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let type = userInfo["type"] as? String, type == "saveTranscript" {
            _ = handleSaveTranscript(userInfo)
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        handleBinaryMessage(messageData)
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        handleBinaryMessage(messageData)
        replyHandler(Data())
    }

    private func handleBinaryMessage(_ data: Data) {
        guard let tag = data.first else { return }
        let payload = data.dropFirst()
        if tag == WCVoiceMessageType.audioFromWatch {
            voiceBridge.receivedAudioFromWatch(Data(payload))
        }
    }

    // MARK: - Voice Connect Handler

    private func handleVoiceConnect(_ message: [String: Any]) {
        guard let key = APIKeychain.load(vendor: VoiceSettings.shared.realtimeVendor.rawValue) else { return }
        let recordingMode = message["recordingMode"] as? String ?? RecordingMode.conversational.rawValue
        let inputMode = message["inputMode"] as? String ?? "interactive"
        let config = WatchSessionConfig(recordingMode: recordingMode, inputMode: inputMode)
        voiceBridge.start(apiKey: key, config: config)
    }

    // MARK: - Save Handler

    private func handleSaveTranscript(_ message: [String: Any]) -> Bool {
        guard let vault = vaultManager,
              let content = message["content"] as? String,
              let title = message["title"] as? String else {
            return false
        }

        let folder = message["folder"] as? String ?? "Assets/Transcriptions"
        let filename = title + ".md"

        let result = vault.createFile(name: filename, folderPath: folder, content: content)
        return result != nil
    }
}
