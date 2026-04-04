import Foundation
import AVFoundation
import os

/// Batch speech-to-text using OpenAI Whisper API.
/// Captures audio, buffers into chunks, and POSTs to /v1/audio/transcriptions.
@Observable
final class OpenAISTTProvider: STTProvider {
    private(set) var text = ""
    private(set) var isActive = false
    private(set) var errorMessage: String?

    private let apiKey: String

    private let audioEngine = AVAudioEngine()
    private var tapInstalled = false
    private let _isStopped = OSAllocatedUnfairLock(initialState: true)

    /// Accumulated PCM16 audio data for the current chunk
    private var audioBuffer = Data()
    private let bufferLock = NSLock()

    /// Timer to periodically flush audio buffer
    private var flushTask: Task<Void, Never>?

    /// All transcribed text so far
    private var committedText = ""

    /// Flush interval in seconds
    private let flushInterval: TimeInterval = 5.0
    private let sampleRate: Double = 16000

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func start() {
        guard !isActive else { return }
        _isStopped.withLock { $0 = false }
        committedText = ""
        text = ""
        audioBuffer = Data()
        errorMessage = nil

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Audio session setup failed: \(error.localizedDescription)"
            return
        }

        startAudioCapture()
        startFlushTimer()
    }

    func stop() {
        _isStopped.withLock { $0 = true }
        flushTask?.cancel()
        flushTask = nil
        stopAudioCapture()

        // Final flush
        Task {
            await flushBuffer()
            await MainActor.run { isActive = false }
        }
    }

    // MARK: - Audio Capture

    private func startAudioCapture() {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            errorMessage = "No microphone input available"
            return
        }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            errorMessage = "Audio format error"
            return
        }

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
            guard let self, !self._isStopped.withLock({ $0 }) else { return }

            let processBuffer: (AVAudioPCMBuffer) -> Void = { buf in
                guard let floatData = buf.floatChannelData?[0] else { return }
                let frameCount = Int(buf.frameLength)
                var int16Data = Data(count: frameCount * 2)
                int16Data.withUnsafeMutableBytes { rawBuffer in
                    let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
                    for i in 0..<frameCount {
                        let sample = max(-1.0, min(1.0, floatData[i]))
                        int16Buffer[i] = Int16(sample * 32767)
                    }
                }
                self.bufferLock.lock()
                self.audioBuffer.append(int16Data)
                self.bufferLock.unlock()
            }

            if let converter {
                let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate)
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }
                var error: NSError?
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error == nil {
                    processBuffer(convertedBuffer)
                }
            } else {
                processBuffer(buffer)
            }
        }
        tapInstalled = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isActive = true
        } catch {
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            stopAudioCapture()
        }
    }

    private func stopAudioCapture() {
        if tapInstalled {
            tapInstalled = false
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        if audioEngine.isRunning { audioEngine.stop() }
    }

    // MARK: - Flush Timer

    private func startFlushTimer() {
        flushTask = Task {
            while !Task.isCancelled && !_isStopped.withLock({ $0 }) {
                try? await Task.sleep(for: .seconds(flushInterval))
                guard !_isStopped.withLock({ $0 }) else { break }
                await flushBuffer()
            }
        }
    }

    // MARK: - Whisper API

    private func flushBuffer() async {
        bufferLock.lock()
        let chunk = audioBuffer
        audioBuffer = Data()
        bufferLock.unlock()

        // Need at least 0.5s of audio (16000 samples/s * 2 bytes * 0.5s = 16000 bytes)
        guard chunk.count >= 16000 else { return }

        do {
            let transcription = try await transcribeChunk(chunk)
            if !transcription.isEmpty {
                await MainActor.run {
                    committedText = joinSegments(committedText, transcription)
                    text = committedText
                }
            }
        } catch {
            DiagnosticLogger.shared.warning("OpenAISTT", "Transcription failed: \(error.localizedDescription)")
        }
    }

    private func transcribeChunk(_ pcm16Data: Data) async throws -> String {
        let wavData = createWAVFile(from: pcm16Data, sampleRate: Int(sampleRate))

        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // File field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        // Model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)
        // Response format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OpenAISTT", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                         userInfo: [NSLocalizedDescriptionKey: errorText])
        }

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Create a minimal WAV file header for PCM16 mono audio
    private func createWAVFile(from pcm16Data: Data, sampleRate: Int) -> Data {
        var wav = Data()
        let channels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let byteRate = Int32(sampleRate * Int(channels) * Int(bitsPerSample / 8))
        let blockAlign = Int16(channels * (bitsPerSample / 8))
        let dataSize = Int32(pcm16Data.count)
        let fileSize = Int32(36 + dataSize)

        wav.append("RIFF".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: Int32(16).littleEndian) { Data($0) })  // chunk size
        wav.append(withUnsafeBytes(of: Int16(1).littleEndian) { Data($0) })   // PCM format
        wav.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: Int32(sampleRate).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        wav.append("data".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wav.append(pcm16Data)

        return wav
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
