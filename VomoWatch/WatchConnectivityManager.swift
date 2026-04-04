import Foundation
import WatchConnectivity

/// Manages WatchConnectivity on the watch side.
/// Syncs API key from phone and sends transcripts for storage.
/// Also handles voice proxy messages (state updates, audio from phone).
@Observable
final class WatchConnectivityManager: NSObject {
    static let shared = WatchConnectivityManager()

    private(set) var apiKey: String?
    private(set) var folders: [String] = []
    private(set) var isPhoneReachable = false
    private(set) var lastSaveSuccess: Bool?

    /// Voice proxy session (set by the voice recording view)
    var voiceProxy: WatchVoiceProxySession?

    private let session = WCSession.default

    override init() {
        super.init()
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
    }

    // MARK: - Requests to Phone

    func requestApiKey() {
        guard session.isReachable else { return }
        session.sendMessage(["type": "requestApiKey"], replyHandler: { reply in
            if let key = reply["key"] as? String {
                Task { @MainActor in self.apiKey = key }
                // Also store locally for offline use
                _ = APIKeychain.save(vendor: VoiceSettings.shared.realtimeVendor.rawValue, key: key)
            }
        }, errorHandler: nil)
    }

    func requestFolders() {
        guard session.isReachable else { return }
        session.sendMessage(["type": "requestFolders"], replyHandler: { reply in
            if let list = reply["folders"] as? [String] {
                Task { @MainActor in self.folders = list }
            }
        }, errorHandler: nil)
    }

    /// Send a transcript to the phone for saving to the vault
    func saveTranscript(title: String, content: String, folder: String, type: String, date: Date) {
        let payload: [String: Any] = [
            "type": "saveTranscript",
            "title": title,
            "content": content,
            "folder": folder,
            "transcriptType": type,
            "date": ISO8601DateFormatter().string(from: date)
        ]

        if session.isReachable {
            session.sendMessage(payload, replyHandler: { reply in
                let success = reply["success"] as? Bool ?? false
                Task { @MainActor in self.lastSaveSuccess = success }
            }, errorHandler: { _ in
                // Fall back to transferUserInfo for background delivery
                self.session.transferUserInfo(payload)
                Task { @MainActor in self.lastSaveSuccess = nil }
            })
        } else {
            // Queue for delivery when phone becomes reachable
            session.transferUserInfo(payload)
        }
    }

    /// Get API key — from sync or local keychain fallback
    var effectiveApiKey: String? {
        apiKey ?? APIKeychain.load(vendor: VoiceSettings.shared.realtimeVendor.rawValue)
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            isPhoneReachable = session.isReachable
        }
        if activationState == .activated {
            requestApiKey()
            requestFolders()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            isPhoneReachable = session.isReachable
        }
        if session.isReachable && apiKey == nil {
            requestApiKey()
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncoming(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleIncoming(message)
        replyHandler([:])
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleIncoming(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        handleBinaryMessage(messageData)
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        handleBinaryMessage(messageData)
        replyHandler(Data())
    }

    private func handleIncoming(_ message: [String: Any]) {
        if let key = message["apiKey"] as? String {
            Task { @MainActor in self.apiKey = key }
            _ = APIKeychain.save(vendor: VoiceSettings.shared.realtimeVendor.rawValue, key: key)
        }
        if let list = message["folderList"] as? [String] {
            Task { @MainActor in self.folders = list }
        }
        // Voice state/transcript updates from phone
        if let type = message["type"] as? String {
            switch type {
            case WCVoiceMessageType.voiceStateUpdate:
                voiceProxy?.handleStateUpdate(message)
            case WCVoiceMessageType.voiceTranscriptUpdate:
                voiceProxy?.handleTranscriptUpdate(message)
            default:
                break
            }
        }
    }

    private func handleBinaryMessage(_ data: Data) {
        guard let tag = data.first else { return }
        let payload = data.dropFirst()
        if tag == WCVoiceMessageType.audioFromPhone {
            voiceProxy?.handleAudioFromPhone(Data(payload))
        }
    }
}
