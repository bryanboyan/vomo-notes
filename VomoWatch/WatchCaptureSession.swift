import Foundation
#if canImport(Speech)
import Speech

/// Manages a quick-capture recording session with pause/resume support.
/// Wraps SpeechTranscriber and accumulates text across pause/resume cycles.
@Observable
final class WatchCaptureSession {
    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var elapsedSeconds = 0
    private(set) var transcribedText = ""

    private let transcriber = SpeechTranscriber()
    private var committedText = ""
    private var segmentStartTime = Date()
    private var accumulatedSeconds = 0
    private var timer: Timer?

    func start() async {
        guard await transcriber.requestAuthorization() else { return }
        committedText = ""
        transcribedText = ""
        elapsedSeconds = 0
        accumulatedSeconds = 0
        segmentStartTime = Date()
        transcriber.start()
        isRecording = true
        isPaused = false
        startTimer()
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        let currentText = transcriber.text
        if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            committedText = joinSegments(committedText, currentText)
            transcribedText = committedText
        }
        accumulatedSeconds = elapsedSeconds
        transcriber.stop()
        isPaused = true
        stopTimer()
    }

    func resume() async {
        guard isPaused else { return }
        guard await transcriber.requestAuthorization() else { return }
        segmentStartTime = Date()
        transcriber.start()
        isPaused = false
        isRecording = true
        startTimer()
    }

    func stop() {
        transcriber.stop()
        isRecording = false
        isPaused = false
        stopTimer()
    }

    func reset() {
        stop()
        committedText = ""
        transcribedText = ""
        elapsedSeconds = 0
        accumulatedSeconds = 0
    }

    var currentText: String {
        if isPaused {
            return transcribedText
        }
        let inProgress = transcriber.text
        if inProgress.isEmpty { return committedText }
        return joinSegments(committedText, inProgress)
    }

    func formatForSave() -> (title: String, content: String) {
        let finalText = currentText
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HH-mm"
        let title = fmt.string(from: now)

        let isoDate = ISO8601DateFormatter().string(from: now)
        let content = """
        ---
        type: quick
        saved: false
        title: ""
        date: \(isoDate)
        duration: \(elapsedSeconds)
        source: watch
        ---

        \(finalText)
        """
        return (title, content)
    }

    var formattedTime: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    var hasContent: Bool {
        !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Private

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.elapsedSeconds = self.accumulatedSeconds + Int(Date().timeIntervalSince(self.segmentStartTime))
                if !self.isPaused {
                    let inProgress = self.transcriber.text
                    if !inProgress.isEmpty {
                        self.transcribedText = self.joinSegments(self.committedText, inProgress)
                    }
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func joinSegments(_ a: String, _ b: String) -> String {
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        let trimmed = a.trimmingCharacters(in: .whitespaces)
        let lastChar = trimmed.last ?? " "
        let sep = lastChar.isPunctuation ? " " : ". "
        return trimmed + sep + b
    }
}
#else
@Observable
final class WatchCaptureSession {
    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var elapsedSeconds = 0
    private(set) var transcribedText = ""
    var currentText: String { "" }
    var formattedTime: String { "0:00" }
    var hasContent: Bool { false }
    func start() async {}
    func pause() {}
    func resume() async {}
    func stop() {}
    func reset() {}
    func formatForSave() -> (title: String, content: String) { ("", "") }
}
#endif
