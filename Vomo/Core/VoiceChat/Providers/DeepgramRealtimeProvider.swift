import Foundation
import AVFoundation
import os
import UIKit

/// Deepgram voice agent realtime provider.
/// Uses wss://agent.deepgram.com/v1/agent/converse with Token auth.
/// Different event protocol from OpenAI — requires 5s keep-alive.
@Observable
final class DeepgramRealtimeProvider: NSObject, RealtimeVoiceProvider {
    private(set) var state: VoiceChatState = .disconnected
    let transcript = TranscriptManager()

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var inputTapInstalled = false
    private var keepAliveTask: Task<Void, Never>?

    private let _isDisconnected = OSAllocatedUnfairLock(initialState: true)

    // Deepgram uses 16kHz for input, 24kHz for output
    private let inputSampleRate: Double = 16000
    private let outputSampleRate: Double = 24000
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    var voice: String = "aura-2-helena-en"
    var isCapturingAudio: Bool = true
    var onMessage: ((String, [String: Any]) -> Bool)?
    var tools: [[String: Any]] = []
    var onAudioOutput: ((Data) -> Void)?
    var onStateChange: ((VoiceChatState) -> Void)?
    var onTranscriptChange: ((TranscriptManager) -> Void)?

    // MARK: - Connect

    func connect(apiKey: String, documentContent: String, systemInstructions: String? = nil) {
        guard state == .disconnected || state != .connecting else { return }
        state = .connecting
        _isDisconnected.withLock { $0 = false }
        print("🎙️ [DEEPGRAM] Connecting to voice agent...")

        guard let url = URL(string: "wss://agent.deepgram.com/v1/agent/converse") else {
            state = .error("Invalid Deepgram URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        urlSession = session
        webSocket = session.webSocketTask(with: request)
        webSocket?.resume()

        startReceiving()

        // Send agent config after connection
        Task {
            let systemPrompt = systemInstructions ?? """
            You are a helpful reading assistant. The user has opened a document and wants to discuss it with you. \
            Answer questions, provide insights, and help them understand the content.
            """

            var agentConfig: [String: Any] = [
                "type": "SettingsConfiguration",
                "audio": [
                    "input": [
                        "encoding": "linear16",
                        "sample_rate": Int(inputSampleRate)
                    ],
                    "output": [
                        "encoding": "linear16",
                        "sample_rate": Int(outputSampleRate),
                        "container": "none"
                    ]
                ] as [String: Any],
                "agent": [
                    "listen": [
                        "model": "nova-3"
                    ],
                    "think": [
                        "provider": [
                            "type": "open_ai"
                        ],
                        "model": "gpt-4o-mini",
                        "instructions": systemPrompt
                    ] as [String: Any],
                    "speak": [
                        "model": voice
                    ]
                ] as [String: Any]
            ]

            if !tools.isEmpty {
                // Deepgram uses "functions" for tool definitions
                var thinkDict = (agentConfig["agent"] as? [String: Any])?["think"] as? [String: Any] ?? [:]
                thinkDict["functions"] = tools
                var agentDict = agentConfig["agent"] as? [String: Any] ?? [:]
                agentDict["think"] = thinkDict
                agentConfig["agent"] = agentDict
            }

            await sendJSON(agentConfig)
            startKeepAlive()
            startAudioCapture()

            await MainActor.run {
                guard self.state != .disconnected else { return }
                state = .connected
                onStateChange?(.connected)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    func disconnect() {
        _isDisconnected.withLock { $0 = true }
        state = .disconnected
        keepAliveTask?.cancel()
        keepAliveTask = nil
        stopAudioCapture()
        stopPlayback()
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - Keep-Alive

    private func startKeepAlive() {
        keepAliveTask = Task {
            while !Task.isCancelled && !_isDisconnected.withLock({ $0 }) {
                try? await Task.sleep(for: .seconds(5))
                guard !_isDisconnected.withLock({ $0 }) else { break }
                await sendJSON(["type": "KeepAlive"])
            }
        }
    }

    // MARK: - Audio Capture

    private func startAudioCapture() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
        } catch {
            DiagnosticLogger.shared.error("Audio", "Audio session setup failed: \(error.localizedDescription)")
            Task { @MainActor in state = .error("Audio session setup failed") }
            return
        }

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: outputFormat)

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Task { @MainActor in state = .error("No microphone input available") }
            return
        }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false) else {
            Task { @MainActor in state = .error("Audio format error") }
            return
        }

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
            guard let self, !self._isDisconnected.withLock({ $0 }), self.isCapturingAudio else { return }

            if let converter {
                let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * self.inputSampleRate / inputFormat.sampleRate)
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }
                var error: NSError?
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error == nil {
                    self.sendAudioData(convertedBuffer)
                }
            } else {
                self.sendAudioData(buffer)
            }
        }
        inputTapInstalled = true

        do {
            try audioEngine.start()
        } catch {
            DiagnosticLogger.shared.error("Audio", "Audio engine failed to start: \(error.localizedDescription)")
            Task { @MainActor in state = .error("Audio engine failed to start") }
        }
    }

    private func stopAudioCapture() {
        if inputTapInstalled {
            inputTapInstalled = false
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        if audioEngine.isRunning { audioEngine.stop() }
        if playerNode.isPlaying { playerNode.stop() }
    }

    private func sendAudioData(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)

        var int16Data = Data(count: frameCount * 2)
        int16Data.withUnsafeMutableBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                let sample = max(-1.0, min(1.0, floatData[i]))
                int16Buffer[i] = Int16(sample * 32767)
            }
        }

        // Deepgram uses binary WebSocket frames (not base64)
        webSocket?.send(.data(int16Data)) { error in
            if let error {
                DiagnosticLogger.shared.warning("DeepgramWS", "Send failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Audio Control

    func commitAudioBuffer() {
        // Deepgram uses continuous streaming — no explicit commit needed.
    }

    func clearAudioBuffer() {
        // No buffer to clear in Deepgram's streaming model
    }

    func updateTurnDetection(enabled: Bool) {
        // Deepgram handles VAD internally — no toggle exposed
    }

    func stopPlayback() {
        if playerNode.isPlaying { playerNode.stop() }
    }

    func injectAudioData(_ int16Data: Data) {
        guard !_isDisconnected.withLock({ $0 }) else { return }
        webSocket?.send(.data(int16Data)) { _ in }
    }

    // MARK: - WebSocket Messaging

    func sendJSON(_ dict: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else { return }
        do {
            try await webSocket?.send(.string(string))
        } catch {
            if !_isDisconnected.withLock({ $0 }) {
                DiagnosticLogger.shared.warning("DeepgramWS", "Send failed: \(error.localizedDescription)")
            }
        }
    }

    private func startReceiving() {
        guard let webSocket, !_isDisconnected.withLock({ $0 }) else { return }
        webSocket.receive { [weak self] result in
            guard let self, !self._isDisconnected.withLock({ $0 }) else { return }
            switch result {
            case .success(.string(let text)):
                self.handleTextMessage(text)
            case .success(.data(let data)):
                self.handleAudioData(data)
            case .failure(let error):
                guard !self._isDisconnected.withLock({ $0 }) else { return }
                Task { @MainActor in
                    self.state = .error(error.localizedDescription)
                }
            @unknown default:
                break
            }
            if !self._isDisconnected.withLock({ $0 }) {
                self.startReceiving()
            }
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if let onMessage, onMessage(type, json) { return }

        switch type {
        case "UserStartedSpeaking":
            stopPlayback()
            Task { @MainActor in
                self.transcript.finalizeAssistantTurn()
                state = .listening
                onStateChange?(.listening)
            }

        case "ConversationText":
            if let role = json["role"] as? String, let content = json["content"] as? String {
                Task { @MainActor in
                    if role == "user" {
                        self.transcript.addUserTurn(content)
                    } else if role == "assistant" {
                        self.transcript.appendToAssistantText(content)
                    }
                    onTranscriptChange?(self.transcript)
                }
            }

        case "AgentStartedSpeaking":
            Task { @MainActor in
                state = .responding
                onStateChange?(.responding)
            }

        case "AgentAudioDone":
            Task { @MainActor in
                self.transcript.finalizeAssistantTurn()
                state = .connected
                onStateChange?(.connected)
            }

        case "Error":
            let msg = json["message"] as? String ?? json["description"] as? String ?? "Deepgram error"
            DiagnosticLogger.shared.error("Deepgram", msg)
            Task { @MainActor in
                state = .error(msg)
                onStateChange?(.error(msg))
            }

        default:
            break
        }
    }

    private func handleAudioData(_ data: Data) {
        if let onAudioOutput {
            onAudioOutput(data)
            return
        }

        let frameCount = data.count / 2
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            guard let floatData = buffer.floatChannelData?[0] else { return }
            for i in 0..<frameCount {
                floatData[i] = Float(int16Buffer[i]) / 32768.0
            }
        }

        if !playerNode.isPlaying { playerNode.play() }
        playerNode.scheduleBuffer(buffer)
    }

    // MARK: - Voice List

    static func fetchVoices(apiKey: String) async throws -> [String] {
        guard let url = URL(string: "https://api.deepgram.com/v1/models") else {
            return VoiceSettings.defaultVoices[.deepgram] ?? []
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return VoiceSettings.defaultVoices[.deepgram] ?? []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tts = json["tts"] as? [[String: Any]] else {
            return VoiceSettings.defaultVoices[.deepgram] ?? []
        }

        let voices = tts.compactMap { model -> String? in
            guard let name = model["name"] as? String,
                  name.hasPrefix("aura-2-"),
                  name.hasSuffix("-en") else { return nil }
            return name
        }

        return voices.isEmpty ? (VoiceSettings.defaultVoices[.deepgram] ?? []) : voices
    }
}

// MARK: - URLSessionWebSocketDelegate

extension DeepgramRealtimeProvider: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        print("🎙️ [DEEPGRAM] WebSocket opened")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("🎙️ [DEEPGRAM] WebSocket closed (code=\(closeCode.rawValue))")
        Task { @MainActor in state = .disconnected }
    }
}
