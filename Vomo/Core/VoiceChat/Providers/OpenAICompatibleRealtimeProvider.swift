import Foundation
import AVFoundation
import os
import UIKit

/// Base class for OpenAI-compatible realtime voice providers (xAI, OpenAI, etc.).
/// Subclasses override `wsURL(apiKey:)` and `configureAuth(request:apiKey:)` to
/// target different endpoints while sharing all WebSocket + audio plumbing.
@Observable
class OpenAICompatibleRealtimeProvider: NSObject, RealtimeVoiceProvider {
    private(set) var state: VoiceChatState = .disconnected
    let transcript = TranscriptManager()

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var inputTapInstalled = false

    // Audio diagnostic tracking
    private var audioDeltaCount = 0
    private var audioBytesTotal = 0
    private var currentResponseId: String?
    private var responseStartTime: Date?

    /// Thread-safe flag to avoid reading `state` (which contains a ref-counted String in .error)
    /// from background threads. Prevents the EXC_BAD_ACCESS crash in startReceiving().
    private let _isDisconnected = OSAllocatedUnfairLock(initialState: true)

    // Audio format: 24kHz mono PCM16
    private let sampleRate: Double = 24000
    // Note: can't use `lazy` with @Observable — it turns properties into computed
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    var voice: String = "Ara"

    /// When false, microphone audio is not sent to the WebSocket (for PTT mode)
    var isCapturingAudio: Bool = true

    /// Hook for external message interception (e.g., tool call handling).
    /// Return `true` to indicate the message was handled and should not be processed by the default handler.
    var onMessage: ((String, [String: Any]) -> Bool)?

    /// Additional tools to include in session.update config
    var tools: [[String: Any]] = []

    /// Continuation for waiting on session.created before starting audio.
    /// Access must be serialized — only mutate from the same Task/actor context.
    private var sessionReadyContinuation: CheckedContinuation<Void, Never>?
    /// Guard to ensure the continuation is resumed exactly once.
    private var sessionReadyResumed = false

    // MARK: - Subclass Overrides

    /// Returns the WebSocket URL for this provider. Subclasses must override.
    func wsURL(apiKey: String) -> URL? {
        fatalError("Subclasses must override wsURL(apiKey:)")
    }

    /// Configures authentication headers on the URLRequest. Subclasses must override.
    func configureAuth(request: inout URLRequest, apiKey: String) {
        fatalError("Subclasses must override configureAuth(request:apiKey:)")
    }

    /// Fetch available voices for this provider. Returns empty by default.
    class func fetchVoices(apiKey: String) async throws -> [String] {
        return []
    }

    // MARK: - Connect

    func connect(apiKey: String, documentContent: String, systemInstructions: String? = nil) {
        guard state == .disconnected || state != .connecting else { return }
        state = .connecting
        _isDisconnected.withLock { $0 = false }
        sessionReadyResumed = false
        print("🎙️ [VOICE] Connecting to realtime API...")

        guard let url = wsURL(apiKey: apiKey) else {
            state = .error("Invalid API URL")
            return
        }
        var request = URLRequest(url: url)
        configureAuth(request: &request, apiKey: apiKey)
        request.timeoutInterval = 15

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        urlSession = session
        webSocket = session.webSocketTask(with: request)
        webSocket?.resume()
        print("🎙️ [VOICE] WebSocket task resumed, waiting for connection...")

        // Start receiving first, then send config and wait for session.created
        startReceiving()
        Task {
            print("🎙️ [VOICE] Sending session config...")
            await sendSessionConfig(documentContent: documentContent, instructions: systemInstructions)
            print("🎙️ [VOICE] Session config sent, waiting for session.created...")

            // Wait for session.created/session.updated (with 5s timeout)
            await withCheckedContinuation { continuation in
                sessionReadyContinuation = continuation
                // Timeout fallback — start audio even if we never get session.created
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    self.resumeSessionContinuation(reason: "timeout")
                }
            }

            // Don't start audio if we disconnected while waiting
            guard state != .disconnected else { return }

            print("🎙️ [VOICE] Session ready, starting audio capture...")
            startAudioCapture()
            print("🎙️ [VOICE] ✅ Audio capture started, isCapturingAudio=\(isCapturingAudio)")
            await MainActor.run {
                guard self.state != .disconnected else { return }
                state = .connected
                onStateChange?(.connected)
                // Haptic to signal voice mode is fully ready
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    /// Safely resume the session-ready continuation exactly once.
    private func resumeSessionContinuation(reason: String) {
        guard !sessionReadyResumed else { return }
        sessionReadyResumed = true
        if reason == "timeout" {
            print("🎙️ [VOICE] ⚠️ Timeout waiting for session.created, starting audio anyway")
        }
        sessionReadyContinuation?.resume()
        sessionReadyContinuation = nil
    }

    func disconnect() {
        _isDisconnected.withLock { $0 = true }
        state = .disconnected
        resumeSessionContinuation(reason: "disconnect")
        stopAudioCapture()
        stopPlayback()
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - Session Configuration

    private func sendSessionConfig(documentContent: String, instructions: String?) async {
        let systemPrompt = instructions ?? """
        You are a helpful reading assistant. The user has opened the following document and wants to discuss it with you. \
        Answer questions, provide insights, and help them understand the content.

        <document>
        \(documentContent)
        </document>
        """

        var sessionDict: [String: Any] = [
            "voice": voice,
            "instructions": systemPrompt,
            "turn_detection": [
                "type": "server_vad",
                "threshold": 0.5,
                "silence_duration_ms": 600,
                "prefix_padding_ms": 500
            ] as [String: Any],
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24000] as [String: Any]
                ] as [String: Any],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24000] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]
        ]
        if !tools.isEmpty {
            sessionDict["tools"] = tools
        }
        let config: [String: Any] = [
            "type": "session.update",
            "session": sessionDict
        ]

        await sendJSON(config)
    }

    // MARK: - Audio Capture (Microphone → WebSocket)

    private func startAudioCapture() {
        print("🎙️ [AUDIO] Setting up AVAudioSession...")
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
            print("🎙️ [AUDIO] AVAudioSession active (sampleRate=\(audioSession.sampleRate), channels=\(audioSession.inputNumberOfChannels))")
        } catch {
            print("🎙️ [AUDIO] ❌ Audio session setup failed: \(error)")
            DiagnosticLogger.shared.error("Audio", "Audio session setup failed: \(error.localizedDescription)")
            Task { @MainActor in state = .error("Audio session setup failed") }
            return
        }

        // Setup audio engine
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: outputFormat)

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("🎙️ [AUDIO] Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        // Validate input format — on some devices the input node can return 0 Hz
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            print("🎙️ [AUDIO] ❌ Invalid input format (sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount))")
            DiagnosticLogger.shared.error("Audio", "Invalid input format: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")
            Task { @MainActor in state = .error("No microphone input available") }
            return
        }

        // Install tap to capture audio
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            print("🎙️ [AUDIO] ❌ Failed to create target audio format")
            Task { @MainActor in state = .error("Audio format error") }
            return
        }

        // Use a converter if input sample rate differs
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        print("🎙️ [AUDIO] Converter: \(inputFormat.sampleRate)Hz → \(sampleRate)Hz")

        var buffersSent = 0
        inputNode.installTap(onBus: 0, bufferSize: 2400, format: inputFormat) { [weak self] buffer, _ in
            guard let self, !self._isDisconnected.withLock({ $0 }) else { return }

            if let converter {
                let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate)
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
                    DiagnosticLogger.shared.error("Audio", "❌ Converted buffer allocation failed (frames=\(frameCount))")
                    return
                }
                var error: NSError?
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if let error {
                    DiagnosticLogger.shared.warning("Audio", "⚠️ Audio converter error: \(error.localizedDescription)")
                } else {
                    self.sendAudioBuffer(convertedBuffer)
                    buffersSent += 1
                    if buffersSent <= 3 || buffersSent % 100 == 0 {
                        print("🎙️ [AUDIO] Buffer #\(buffersSent) sent (\(convertedBuffer.frameLength) frames, capturing=\(self.isCapturingAudio))")
                    }
                }
            } else {
                self.sendAudioBuffer(buffer)
            }
        }
        inputTapInstalled = true

        do {
            try audioEngine.start()
            print("🎙️ [AUDIO] ✅ Audio engine started, tap installed")
        } catch {
            print("🎙️ [AUDIO] ❌ Audio engine failed to start: \(error)")
            DiagnosticLogger.shared.error("Audio", "Audio engine failed to start: \(error.localizedDescription)")
            Task { @MainActor in state = .error("Audio engine failed to start") }
        }
    }

    private func stopAudioCapture() {
        // Remove tap before stopping engine to avoid callback during teardown
        if inputTapInstalled {
            inputTapInstalled = false
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if playerNode.isPlaying {
            playerNode.stop()
        }
    }

    private func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isCapturingAudio, !_isDisconnected.withLock({ $0 }) else { return }
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

        let base64Audio = int16Data.base64EncodedString()
        let message: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]
        Task { await sendJSON(message) }
    }

    // MARK: - External Audio Injection (Watch Proxy)

    /// Inject raw Int16 PCM audio from an external source (e.g., watch mic via WatchConnectivity).
    /// Bypasses local mic tap — sends directly to the WebSocket.
    func injectAudioData(_ int16Data: Data) {
        guard !_isDisconnected.withLock({ $0 }) else { return }
        let base64Audio = int16Data.base64EncodedString()
        let message: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]
        Task { await sendJSON(message) }
    }

    /// Hook for intercepting outgoing audio data (raw Int16 PCM).
    /// Used by WatchVoiceBridge to relay xAI audio back to the watch.
    var onAudioOutput: ((Data) -> Void)?

    /// Hook for state change notifications (called on MainActor)
    var onStateChange: ((VoiceChatState) -> Void)?

    /// Hook for transcript change notifications (called on MainActor)
    var onTranscriptChange: ((TranscriptManager) -> Void)?

    // MARK: - PTT Support

    /// Commit the audio buffer and trigger a response (for PTT mode)
    func commitAudioBuffer() {
        Task {
            await sendJSON(["type": "input_audio_buffer.commit"])
            await sendJSON(["type": "response.create"])
        }
    }

    /// Clear uncommitted audio from the buffer
    func clearAudioBuffer() {
        Task {
            await sendJSON(["type": "input_audio_buffer.clear"])
        }
    }

    /// Toggle server-side VAD on or off
    func updateTurnDetection(enabled: Bool) {
        let turnDetection: Any = enabled
            ? [
                "type": "server_vad",
                "threshold": 0.5,
                "silence_duration_ms": 600,
                "prefix_padding_ms": 500
            ] as [String: Any]
            : NSNull()

        let config: [String: Any] = [
            "type": "session.update",
            "session": [
                "turn_detection": turnDetection
            ]
        ]
        Task { await sendJSON(config) }
    }

    // MARK: - Audio Playback (WebSocket → Speaker)

    private func playAudioData(_ base64: String) {
        guard let pcmData = Data(base64Encoded: base64) else {
            DiagnosticLogger.shared.warning("Audio", "⚠️ Base64 decode failed for audio delta (length=\(base64.count))")
            return
        }

        // Track bytes
        audioBytesTotal += pcmData.count

        // If an external audio handler is set (watch proxy mode), forward raw PCM instead of playing locally
        if let onAudioOutput {
            onAudioOutput(pcmData)
            return
        }

        let frameCount = pcmData.count / 2 // 2 bytes per Int16 sample

        guard frameCount > 0 else {
            DiagnosticLogger.shared.warning("Audio", "⚠️ Empty audio delta (0 frames)")
            return
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            DiagnosticLogger.shared.error("Audio", "❌ PCMBuffer allocation failed (frames=\(frameCount), format=\(outputFormat))")
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        // Convert Int16 PCM → Float32
        pcmData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            guard let floatData = buffer.floatChannelData?[0] else {
                DiagnosticLogger.shared.error("Audio", "❌ floatChannelData is nil during PCM conversion")
                return
            }
            for i in 0..<frameCount {
                floatData[i] = Float(int16Buffer[i]) / 32768.0
            }
        }

        if !playerNode.isPlaying {
            print("🎙️ [AUDIO] ▶️ Starting playerNode playback (delta #\(audioDeltaCount))")
            playerNode.play()
        }
        playerNode.scheduleBuffer(buffer)
    }

    func stopPlayback() {
        if playerNode.isPlaying {
            print("🎙️ [AUDIO] ⏹️ Stopping playback")
        }
        playerNode.stop()
    }

    // MARK: - WebSocket Messaging

    func sendJSON(_ dict: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else {
            let type = dict["type"] as? String ?? "unknown"
            DiagnosticLogger.shared.error("WebSocket", "❌ Failed to serialize JSON for type=\(type)")
            return
        }
        do {
            try await webSocket?.send(.string(string))
        } catch {
            let type = dict["type"] as? String ?? "unknown"
            // Don't spam errors for audio buffer appends during disconnect
            if !_isDisconnected.withLock({ $0 }) {
                DiagnosticLogger.shared.warning("WebSocket", "⚠️ Send failed for type=\(type): \(error.localizedDescription)")
            }
        }
    }

    private func startReceiving() {
        guard let webSocket, !_isDisconnected.withLock({ $0 }) else { return }
        webSocket.receive { [weak self] result in
            guard let self, !self._isDisconnected.withLock({ $0 }) else { return }
            switch result {
            case .success(.string(let text)):
                self.handleMessage(text)
            case .failure(let error):
                // Don't report errors if we intentionally disconnected
                guard !self._isDisconnected.withLock({ $0 }) else { return }
                DiagnosticLogger.shared.error("WebSocket", "Receive failed: \(error.localizedDescription)")
                Task { @MainActor in
                    guard self.state != .disconnected else { return }
                    self.state = .error(error.localizedDescription)
                }
            default:
                break
            }
            // Continue receiving
            if !self._isDisconnected.withLock({ $0 }) {
                self.startReceiving()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            DiagnosticLogger.shared.warning("WebSocket", "⚠️ Failed to parse incoming message (length=\(text.count), prefix=\(String(text.prefix(100))))")
            return
        }

        // Let external handler intercept first
        if let onMessage, onMessage(type, json) {
            return
        }

        switch type {
        case "session.created", "session.updated":
            print("🎙️ [VOICE] Received \(type)")
            resumeSessionContinuation(reason: type)

        case "input_audio_buffer.speech_started":
            let wasPlaying = playerNode.isPlaying
            if wasPlaying {
                print("🎙️ [VAD] Speech detected — INTERRUPTING playback (had received \(audioDeltaCount) deltas)")
                DiagnosticLogger.shared.info("Audio", "Playback interrupted by speech (deltas played=\(audioDeltaCount), bytes=\(audioBytesTotal))")
            } else {
                print("🎙️ [VAD] Speech detected")
            }
            Task { @MainActor in
                self.transcript.finalizeAssistantTurn()
                state = .listening
                onStateChange?(.listening)
            }
            stopPlayback()

        case "input_audio_buffer.speech_stopped":
            print("🎙️ [VAD] Speech ended")
            Task { @MainActor in
                state = .connected
                onStateChange?(.connected)
            }

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String {
                Task { @MainActor in
                    self.transcript.addUserTurn(transcript)
                    onTranscriptChange?(self.transcript)
                }
            }

        case "response.created":
            // Track response lifecycle
            currentResponseId = (json["response"] as? [String: Any])?["id"] as? String
            audioDeltaCount = 0
            audioBytesTotal = 0
            responseStartTime = Date()
            print("🎙️ [RESPONSE] Started (id=\(currentResponseId ?? "?"))")
            Task { @MainActor in
                state = .responding
                onStateChange?(.responding)
            }

        case "response.output_audio.delta":
            if let delta = json["delta"] as? String {
                audioDeltaCount += 1
                if audioDeltaCount <= 3 || audioDeltaCount % 50 == 0 {
                    print("🎙️ [AUDIO] 📥 Delta #\(audioDeltaCount) received (base64 len=\(delta.count))")
                }
                playAudioData(delta)
            } else {
                DiagnosticLogger.shared.warning("Audio", "⚠️ response.output_audio.delta missing 'delta' key: \(json.keys.sorted())")
            }

        case "response.output_audio_transcript.delta":
            if let delta = json["delta"] as? String {
                Task { @MainActor in
                    self.transcript.appendToAssistantText(delta)
                    onTranscriptChange?(self.transcript)
                }
            }

        case "response.output_audio_transcript.done":
            Task { @MainActor in
                self.transcript.finalizeAssistantTurn()
                onTranscriptChange?(self.transcript)
            }

        case "response.done":
            let elapsed = responseStartTime.map { Date().timeIntervalSince($0) } ?? 0
            let status = (json["response"] as? [String: Any])?["status"] as? String ?? "?"
            print("🎙️ [RESPONSE] Done (id=\(currentResponseId ?? "?"), status=\(status), deltas=\(audioDeltaCount), bytes=\(audioBytesTotal), elapsed=\(String(format: "%.1f", elapsed))s)")
            if audioDeltaCount == 0 {
                DiagnosticLogger.shared.warning("Audio", "⚠️ Response completed with ZERO audio deltas (id=\(currentResponseId ?? "?"), status=\(status))")
            }
            DiagnosticLogger.shared.info("Audio", "Response done: \(audioDeltaCount) deltas, \(audioBytesTotal) bytes, \(String(format: "%.1f", elapsed))s (status=\(status))")
            Task { @MainActor in
                self.transcript.finalizeAssistantTurn()
                state = .connected
                onStateChange?(.connected)
            }

        case "error":
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            DiagnosticLogger.shared.error("VoiceAPI", "API error: \(msg)")
            Task { @MainActor in
                state = .error(msg)
                onStateChange?(.error(msg))
            }

        default:
            // Log unknown message types at debug level for awareness
            if !["response.output_audio_transcript.delta", "response.content_part.added", "response.content_part.done", "response.output_item.added", "conversation.item.created", "rate_limits.updated"].contains(type) {
                print("🎙️ [WS] Unhandled message type: \(type)")
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension OpenAICompatibleRealtimeProvider: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        print("🎙️ [WS] WebSocket opened (protocol: \(proto ?? "none"))")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        print("🎙️ [WS] WebSocket closed (code=\(closeCode.rawValue), reason=\(reasonStr))")
        DiagnosticLogger.shared.info("WebSocket", "Connection closed (code=\(closeCode.rawValue), reason=\(reasonStr))")
        Task { @MainActor in
            state = .disconnected
        }
    }
}
