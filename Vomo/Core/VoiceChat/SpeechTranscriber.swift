import Foundation
#if canImport(Speech)
import Speech
import AVFoundation

/// Wraps SFSpeechRecognizer + AVAudioEngine for live on-device speech-to-text.
/// Automatically restarts recognition tasks on timeout to support unlimited duration.
@Observable
final class SpeechTranscriber {
    private(set) var text = ""
    private(set) var isActive = false
    private(set) var errorMessage: String?

    /// Additional context strings to improve recognition accuracy (e.g. domain-specific vocabulary)
    var contextualStrings: [String] = []
    /// Additional STT instructions (loaded from .vomo/stt_instructions.txt), available for post-processing
    var sttInstructions: String?

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var tapInstalled = false
    /// Text from previous finalized recognition segments
    private var committedText = ""
    /// Last known segment text (for committing on error without isFinal)
    private var lastSegmentText = ""
    /// Whether we intentionally stopped (vs auto-restart on segment end)
    private var userStopped = false

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale.current)
        print("🎤 [SpeechTranscriber] Initialized with locale: \(Locale.current.identifier)")
    }

    func requestAuthorization() async -> Bool {
        print("🎤 [SpeechTranscriber] Requesting authorization...")
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        print("🎤 [SpeechTranscriber] Authorization status: \(status.rawValue)")
        if status != .authorized {
            await MainActor.run { errorMessage = "Speech recognition not authorized" }
            return false
        }
        return true
    }

    func start() {
        print("🎤 [SpeechTranscriber] START called")
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition unavailable"
            #if !os(watchOS)
            DiagnosticLogger.shared.error("Speech", "Speech recognizer not available")
            #endif
            print("🎤 [SpeechTranscriber] ❌ Recognizer not available")
            return
        }

        userStopped = false
        committedText = ""
        text = ""
        print("🎤 [SpeechTranscriber] Reset state: committedText='', text='', userStopped=false")
        stopRecognitionTask()

        do {
            let audioSession = AVAudioSession.sharedInstance()
            #if os(watchOS)
            try audioSession.setCategory(.record, mode: .default, options: [])
            try audioSession.setActive(true)
            #else
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            print("🎤 [SpeechTranscriber] ✅ Audio session configured")
        } catch {
            errorMessage = "Audio session setup failed: \(error.localizedDescription)"
            #if !os(watchOS)
            DiagnosticLogger.shared.error("Speech", "Audio session setup failed: \(error.localizedDescription)")
            #endif
            print("🎤 [SpeechTranscriber] ❌ Audio session error: \(error)")
            return
        }

        startAudioEngine()
        startRecognitionTask()
    }

    func stop() {
        print("🎤 [SpeechTranscriber] STOP called")
        userStopped = true
        stopRecognitionTask()
        stopAudioEngine()
        isActive = false
        print("🎤 [SpeechTranscriber] Stopped. Final text length: \(text.count) chars")
    }

    // MARK: - Audio Engine

    private func startAudioEngine() {
        print("🎤 [SpeechTranscriber] Starting audio engine...")
        guard !audioEngine.isRunning else {
            print("🎤 [SpeechTranscriber] Audio engine already running")
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        tapInstalled = true
        print("🎤 [SpeechTranscriber] Audio tap installed")

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isActive = true
            errorMessage = nil
            print("🎤 [SpeechTranscriber] ✅ Audio engine started, isActive=true")
        } catch {
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            #if !os(watchOS)
            DiagnosticLogger.shared.error("Speech", "Audio engine failed to start: \(error.localizedDescription)")
            #endif
            print("🎤 [SpeechTranscriber] ❌ Audio engine start failed: \(error)")
            stopAudioEngine()
        }
    }

    private func stopAudioEngine() {
        print("🎤 [SpeechTranscriber] Stopping audio engine...")
        if audioEngine.isRunning {
            audioEngine.stop()
            print("🎤 [SpeechTranscriber] Audio engine stopped")
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            print("🎤 [SpeechTranscriber] Audio tap removed")
        }
    }

    // MARK: - Recognition Task (auto-restarts on segment end)

    private func startRecognitionTask() {
        print("🎤 [SpeechTranscriber] Starting recognition task...")
        print("🎤 [SpeechTranscriber] Current state: committedText='\(committedText.prefix(50))...', lastSegmentText='\(lastSegmentText.prefix(50))...'")
        
        guard let recognizer, recognizer.isAvailable else {
            print("🎤 [SpeechTranscriber] ❌ Recognizer not available")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
            print("🎤 [SpeechTranscriber] Contextual strings: \(contextualStrings.prefix(5))")
        }
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            print("🎤 [SpeechTranscriber] Using on-device recognition")
        }
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let segmentText = result.bestTranscription.formattedString
                    let isFinal = result.isFinal
                    
                    print("🎤 [SpeechTranscriber] 📝 Result received: isFinal=\(isFinal), segmentLength=\(segmentText.count)")
                    print("🎤 [SpeechTranscriber]    committedText length: \(self.committedText.count)")
                    print("🎤 [SpeechTranscriber]    lastSegmentText length: \(self.lastSegmentText.count)")
                    print("🎤 [SpeechTranscriber]    new segmentText: '\(segmentText.prefix(80))...'")
                    
                    // Detect if Apple's recognizer auto-restarted with a new segment
                    // This happens when segment text suddenly becomes much shorter
                    let segmentRestarted = !self.lastSegmentText.isEmpty && 
                                          segmentText.count < self.lastSegmentText.count &&
                                          segmentText.count < 50  // New segments typically start small
                    
                    if segmentRestarted {
                        print("🎤 [SpeechTranscriber] 🔄 Auto-segment detected! Committing previous segment first")
                        print("🎤 [SpeechTranscriber]    Committing: '\(self.lastSegmentText.prefix(50))...' (\(self.lastSegmentText.count) chars)")
                        // Commit the previous segment before processing the new one
                        self.committedText = self.joinSegments(self.committedText, self.lastSegmentText)
                    }
                    
                    self.lastSegmentText = segmentText
                    let newText = self.joinSegments(self.committedText, segmentText)
                    print("🎤 [SpeechTranscriber]    joined text length: \(newText.count)")
                    self.text = newText

                    if result.isFinal {
                        print("🎤 [SpeechTranscriber] 🔄 FINAL result - committing segment and restarting")
                        print("🎤 [SpeechTranscriber]    OLD committedText: '\(self.committedText.prefix(50))...'")
                        // Segment finalized — commit and restart for continuous transcription
                        self.committedText = self.text
                        print("🎤 [SpeechTranscriber]    NEW committedText: '\(self.committedText.prefix(50))...'")
                        self.lastSegmentText = ""
                        self.restartRecognitionTask()
                        return
                    }
                }
                if let error {
                    let nsError = error as NSError
                    let isCancellation = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216
                    
                    print("🎤 [SpeechTranscriber] ⚠️ Error received: \(nsError)")
                    print("🎤 [SpeechTranscriber]    isCancellation: \(isCancellation)")

                    if isCancellation {
                        print("🎤 [SpeechTranscriber] Ignoring cancellation error")
                        // Our own cancel — do nothing
                        return
                    }

                    // Any other error (timeout, no speech, etc.): commit what we have and restart
                    print("🎤 [SpeechTranscriber] 🔄 Non-cancellation error - committing and restarting")
                    if !self.lastSegmentText.isEmpty {
                        print("🎤 [SpeechTranscriber]    Committing lastSegmentText: '\(self.lastSegmentText.prefix(50))...'")
                        self.committedText = self.joinSegments(self.committedText, self.lastSegmentText)
                        self.text = self.committedText
                        self.lastSegmentText = ""
                    }
                    self.restartRecognitionTask()
                }
            }
        }
        print("🎤 [SpeechTranscriber] ✅ Recognition task started")
    }

    private func stopRecognitionTask() {
        print("🎤 [SpeechTranscriber] Stopping recognition task...")
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        print("🎤 [SpeechTranscriber] Recognition task stopped")
    }

    private func restartRecognitionTask() {
        print("🎤 [SpeechTranscriber] 🔄 RESTART called, userStopped=\(userStopped)")
        guard !userStopped else {
            print("🎤 [SpeechTranscriber] User stopped - not restarting")
            return
        }
        stopRecognitionTask()
        print("🎤 [SpeechTranscriber] Restarting with committedText length: \(committedText.count)")
        startRecognitionTask()
    }

    /// Join committed text with current segment, ensuring proper spacing and punctuation
    private func joinSegments(_ committed: String, _ current: String) -> String {
        guard !committed.isEmpty else {
            print("🎤 [SpeechTranscriber] joinSegments: committed empty, returning current")
            return current
        }
        guard !current.isEmpty else {
            print("🎤 [SpeechTranscriber] joinSegments: current empty, returning committed")
            return committed
        }

        let trimmedCommitted = committed.trimmingCharacters(in: .whitespaces)
        let lastChar = trimmedCommitted.last ?? " "
        let needsPeriod = !lastChar.isPunctuation
        let separator = needsPeriod ? ". " : " "
        
        let result = trimmedCommitted + separator + current
        print("🎤 [SpeechTranscriber] joinSegments: '\(trimmedCommitted.suffix(30))' + '\(separator)' + '\(current.prefix(30))' = \(result.count) chars")

        return result
    }
}
#endif
