import Foundation
import AVFoundation
import os

/// WebSocket-based speech-to-text client that streams audio to a server.
/// Mirrors SpeechTranscriber's public interface (text, isActive, start/stop)
/// so callers can swap between Apple on-device and server STT.
@Observable
final class ServerSpeechTranscriber {
    private(set) var text = ""
    private(set) var isActive = false
    private(set) var errorMessage: String?

    private let serverURL: String
    private let serverToken: String

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let audioEngine = AVAudioEngine()
    private var tapInstalled = false

    /// Thread-safe flag to avoid reading @Observable `isActive` from audio/WebSocket threads.
    private let _isStopped = OSAllocatedUnfairLock(initialState: true)

    /// Text from previous finalized segments
    private var committedText = ""

    init(serverURL: String, serverToken: String) {
        self.serverURL = serverURL
        self.serverToken = serverToken
    }

    func start() {
        guard !isActive else { return }
        _isStopped.withLock { $0 = false }
        committedText = ""
        text = ""
        errorMessage = nil

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Audio session setup failed: \(error.localizedDescription)"
            DiagnosticLogger.shared.error("ServerSTT", "Audio session setup failed: \(error.localizedDescription)")
            return
        }

        connectWebSocket()
    }

    func stop() {
        _isStopped.withLock { $0 = true }
        isActive = false
        stopAudioCapture()
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - WebSocket

    private func connectWebSocket() {
        guard let url = URL(string: "wss://\(serverURL)/v1/stt") else {
            errorMessage = "Invalid server URL"
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(serverToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        urlSession = session
        webSocket = session.webSocketTask(with: request)
        webSocket?.resume()

        startReceiving()
    }

    private func startReceiving() {
        guard let webSocket else { return }
        webSocket.receive { [weak self] result in
            guard let self, !self._isStopped.withLock({ $0 }) else { return }
            switch result {
            case .success(.string(let text)):
                self.handleMessage(text)
            case .failure(let error):
                guard !self._isStopped.withLock({ $0 }) else { return }
                DiagnosticLogger.shared.error("ServerSTT", "WebSocket error: \(error.localizedDescription)")
                Task { @MainActor in
                    self.errorMessage = error.localizedDescription
                    self.isActive = false
                }
            default:
                break
            }
            if !self._isStopped.withLock({ $0 }) {
                self.startReceiving()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "ready":
            Task { @MainActor in
                self.startAudioCapture()
            }

        case "transcript":
            guard let transcriptText = json["text"] as? String else { return }
            let isFinal = json["is_final"] as? Bool ?? false

            Task { @MainActor in
                if isFinal {
                    self.committedText = self.joinSegments(self.committedText, transcriptText)
                    self.text = self.committedText
                } else {
                    self.text = self.joinSegments(self.committedText, transcriptText)
                }
            }

        case "error":
            let msg = json["message"] as? String ?? "Server STT error"
            DiagnosticLogger.shared.error("ServerSTT", msg)
            Task { @MainActor in
                self.errorMessage = msg
            }

        default:
            break
        }
    }

    // MARK: - Audio Capture

    private func startAudioCapture() {
        guard !audioEngine.isRunning else { return }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            errorMessage = "No microphone input available"
            return
        }

        // Target: 16kHz mono PCM16
        let targetSampleRate: Double = 16000
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false) else {
            errorMessage = "Audio format error"
            return
        }

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
            guard let self, !self._isStopped.withLock({ $0 }) else { return }

            if let converter {
                let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * targetSampleRate / inputFormat.sampleRate)
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }
                var error: NSError?
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error == nil {
                    self.sendAudioBuffer(convertedBuffer)
                }
            } else {
                self.sendAudioBuffer(buffer)
            }
        }
        tapInstalled = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isActive = true
        } catch {
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            DiagnosticLogger.shared.error("ServerSTT", "Audio engine failed: \(error.localizedDescription)")
            stopAudioCapture()
        }
    }

    private func stopAudioCapture() {
        if tapInstalled {
            tapInstalled = false
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    private func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)

        // Convert Float32 → Int16 PCM
        var int16Data = Data(count: frameCount * 2)
        int16Data.withUnsafeMutableBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                let sample = max(-1.0, min(1.0, floatData[i]))
                int16Buffer[i] = Int16(sample * 32767)
            }
        }

        // Send as binary WebSocket frame
        webSocket?.send(.data(int16Data)) { error in
            if let error {
                DiagnosticLogger.shared.warning("ServerSTT", "Send failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    private func joinSegments(_ committed: String, _ current: String) -> String {
        guard !committed.isEmpty else { return current }
        guard !current.isEmpty else { return committed }
        let trimmed = committed.trimmingCharacters(in: .whitespaces)
        let lastChar = trimmed.last ?? " "
        let needsPeriod = !lastChar.isPunctuation
        let separator = needsPeriod ? ". " : " "
        return trimmed + separator + current
    }
}
