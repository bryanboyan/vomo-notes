import Foundation
import AVFoundation
import WatchConnectivity

/// Watch-side thin client for voice sessions.
/// Captures mic audio and sends it to the paired iPhone.
/// Receives AI response audio from the iPhone and plays it on the watch speaker.
@Observable
final class WatchVoiceProxySession {
    private(set) var state: VoiceChatState = .disconnected
    private(set) var inputMode: VoiceInputMode = .interactive
    private(set) var isPTTActive = false

    let transcript = TranscriptManager()

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var inputTapInstalled = false
    private let sampleRate: Double = 24000
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    private let wcSession = WCSession.default

    // MARK: - Connect / Disconnect

    func connect(recordingMode: RecordingMode) {
        guard state == .disconnected || state.isError else { return }
        state = .connecting

        guard wcSession.isReachable else {
            state = .error("iPhone not reachable")
            return
        }

        let payload: [String: Any] = [
            "type": WCVoiceMessageType.voiceConnect,
            "recordingMode": recordingMode.rawValue,
            "inputMode": inputMode.rawValue
        ]

        wcSession.sendMessage(payload, replyHandler: { [weak self] _ in
            Task { @MainActor in
                self?.startAudio()
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.state = .error("Failed to connect: \(error.localizedDescription)")
            }
        })
    }

    func disconnect() {
        stopAudio()
        isPTTActive = false

        if wcSession.isReachable {
            wcSession.sendMessage(
                ["type": WCVoiceMessageType.voiceDisconnect],
                replyHandler: nil,
                errorHandler: nil
            )
        }

        state = .disconnected
        transcript.clear()
    }

    // MARK: - Input Mode

    func switchToInteractive() {
        inputMode = .interactive
        isPTTActive = false
        if wcSession.isReachable {
            wcSession.sendMessage(
                ["type": WCVoiceMessageType.voiceModeSwitch, "inputMode": "interactive"],
                replyHandler: nil,
                errorHandler: nil
            )
        }
    }

    func switchToPTT() {
        inputMode = .ptt
        isPTTActive = false
        if wcSession.isReachable {
            wcSession.sendMessage(
                ["type": WCVoiceMessageType.voiceModeSwitch, "inputMode": "ptt"],
                replyHandler: nil,
                errorHandler: nil
            )
        }
    }

    func startPTT() {
        guard inputMode == .ptt else { return }
        isPTTActive = true
        stopPlayback()
        if wcSession.isReachable {
            wcSession.sendMessage(
                ["type": WCVoiceMessageType.voicePTTStart],
                replyHandler: nil,
                errorHandler: nil
            )
        }
    }

    func stopPTT() {
        guard inputMode == .ptt else { return }
        isPTTActive = false
        if wcSession.isReachable {
            wcSession.sendMessage(
                ["type": WCVoiceMessageType.voicePTTStop],
                replyHandler: nil,
                errorHandler: nil
            )
        }
    }

    // MARK: - State Updates from Phone

    func handleStateUpdate(_ message: [String: Any]) {
        guard let stateStr = message["state"] as? String,
              let wcState = WCVoiceState(rawValue: stateStr) else { return }
        let errorMsg = message["errorMessage"] as? String
        Task { @MainActor in
            self.state = wcState.toVoiceChatState(errorMessage: errorMsg)
        }
    }

    func handleTranscriptUpdate(_ message: [String: Any]) {
        guard let turns = message["turns"] as? [[String: String]] else { return }
        let assistantText = message["currentAssistantText"] as? String ?? ""
        Task { @MainActor in
            // Sync transcript — replace entirely from phone's authoritative copy
            self.transcript.replaceAll(turns: turns, currentAssistantText: assistantText)
        }
    }

    // MARK: - Audio from Phone (xAI response)

    func handleAudioFromPhone(_ pcmData: Data) {
        let frameCount = pcmData.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        pcmData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            guard let floatData = buffer.floatChannelData?[0] else { return }
            for i in 0..<frameCount {
                floatData[i] = Float(int16Buffer[i]) / 32768.0
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
        playerNode.scheduleBuffer(buffer)
    }

    // MARK: - Local Audio (Mic Capture + Speaker Playback)

    private func startAudio() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [])
            try audioSession.setActive(true)
        } catch {
            state = .error("Audio setup failed")
            return
        }

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: outputFormat)
        // Boost playback volume — watch speaker is small
        audioEngine.mainMixerNode.outputVolume = 1.0

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            state = .error("No microphone available")
            return
        }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            state = .error("Audio format error")
            return
        }

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 2400, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // In PTT mode, only send when active; in interactive mode, always send
            let shouldSend = self.inputMode == .interactive || self.isPTTActive

            if let converter {
                let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate)
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }
                var error: NSError?
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error == nil, shouldSend {
                    self.sendAudioToPhone(convertedBuffer)
                }
            } else if shouldSend {
                self.sendAudioToPhone(buffer)
            }
        }
        inputTapInstalled = true

        do {
            try audioEngine.start()
            state = .connected
        } catch {
            state = .error("Audio engine failed")
        }
    }

    private func stopAudio() {
        if inputTapInstalled {
            inputTapInstalled = false
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        stopPlayback()
    }

    private func stopPlayback() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
    }

    private func sendAudioToPhone(_ buffer: AVAudioPCMBuffer) {
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

        guard wcSession.isReachable else { return }
        // Tag byte + raw PCM data
        var tagged = Data([WCVoiceMessageType.audioFromWatch])
        tagged.append(int16Data)
        wcSession.sendMessageData(tagged, replyHandler: nil, errorHandler: nil)
    }
}

// Helper for pattern matching VoiceChatState.error
extension VoiceChatState {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}
