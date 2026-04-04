import SwiftUI

/// Single-screen state machine view for the Apple Watch.
/// All interactions via 3 gestures: tap, long-press, swipe ↓.
struct WatchMainView: View {
    @Environment(WatchConnectivityManager.self) var connectivity
    @State private var state: WatchAppState = .ready
    @State private var captureSession = WatchCaptureSession()
    @State private var voiceSession = WatchVoiceProxySession()
    @State private var wristMotion = WristMotionManager()

    // Timers
    @State private var idleTimer: Timer?
    @State private var idleSeconds = 0
    @State private var saveCountdown = 5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            if state.borderColor != .clear {
                state.borderColor.opacity(0.08).ignoresSafeArea()
            }
        }
        .onTapGesture { handleTap() }
        .onLongPressGesture(minimumDuration: 0.5) { handleLongPress() }
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    // Swipe right (left-to-right, like standard watchOS back gesture) to exit
                    let isHorizontalSwipe = abs(value.translation.width) > abs(value.translation.height)
                    if isHorizontalSwipe && value.translation.width > 40 {
                        handleSwipeDown()
                    }
                }
        )
        .onAppear {
            connectivity.voiceProxy = voiceSession
            connectivity.requestApiKey()
            wristMotion.onWristLowered = { handleWristLower() }
        }
        .onDisappear {
            cleanup()
        }
        .onChange(of: voiceSession.state) { _, newState in
            guard state.isVoiceAI else { return }
            switch newState {
            case .error:
                state = .noPhone
            case .disconnected:
                state = .ready
            default:
                break
            }
        }
    }

    // MARK: - Content Router

    @ViewBuilder
    private var content: some View {
        switch state {
        case .ready:
            readyView
        case .recording:
            recordingView
        case .paused:
            pausedView
        case .saveConfirm:
            saveConfirmView
        case .connecting:
            connectingView
        case .voiceInteractive:
            voiceInteractiveView
        case .voicePTT:
            voicePTTView
        case .voicePTTTalking:
            voicePTTTalkingView
        case .noPhone:
            noPhoneView
        case .saved:
            savedView
        }
    }

    // MARK: - Ready State

    private var readyView: some View {
        VStack(spacing: 12) {
            Spacer()

            Text("VOMO")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray.opacity(0.5))
                .tracking(2)

            ZStack {
                Circle()
                    .fill(Color.vomoPurple)
                    .frame(width: 80, height: 80)
                    .shadow(color: .vomoPurple.opacity(0.3), radius: 15)
                Image(systemName: "mic.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
            }

            Text("Tap to capture")
                .font(.system(size: 13))
                .foregroundStyle(.gray)

            Spacer()

            Text("hold for voice AI")
                .font(.system(size: 9))
                .foregroundStyle(.gray.opacity(0.5))
                .padding(.bottom, 8)
        }
    }

    // MARK: - Recording State

    private var recordingView: some View {
        VStack(spacing: 8) {
            // Timer + red dot + exit
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                Text(captureSession.formattedTime)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.red)
                Spacer()
                exitButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer()

            // Animated waveform
            HStack(spacing: 3) {
                ForEach(0..<9, id: \.self) { i in
                    WaveformBar(index: i, isActive: true, color: .red)
                }
            }
            .frame(height: 55)

            Spacer()

            Text("Tap to stop")
                .font(.system(size: 11))
                .foregroundStyle(.gray)

            Text("↓ lower wrist to pause")
                .font(.system(size: 9))
                .foregroundStyle(.gray.opacity(0.5))
                .padding(.bottom, 8)
        }
    }

    // MARK: - Paused State

    private var pausedView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pause.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                Text(captureSession.formattedTime)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.yellow)
            }
            .padding(.top, 8)

            ScrollView {
                Text(captureSession.currentText)
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            .frame(maxHeight: .infinity)

            Text("Tap to resume")
                .font(.system(size: 11))
                .foregroundStyle(.gray)
            Text("Hold to save")
                .font(.system(size: 9))
                .foregroundStyle(.gray.opacity(0.5))

            Text("auto-save in \(idleSeconds)s")
                .font(.system(size: 8))
                .foregroundStyle(.gray.opacity(0.3))
                .padding(.bottom, 6)
        }
    }

    // MARK: - Save Confirm State

    private var saveConfirmView: some View {
        VStack(spacing: 8) {
            Spacer()

            Text(String(captureSession.currentText.prefix(100)) + (captureSession.currentText.count > 100 ? "..." : ""))
                .font(.system(size: 10))
                .foregroundStyle(.gray)
                .lineLimit(3)
                .padding(.horizontal, 16)

            Text("saving in \(saveCountdown)s...")
                .font(.system(size: 9))
                .foregroundStyle(.gray.opacity(0.5))

            HStack(spacing: 16) {
                Button {
                    saveAndReturn()
                } label: {
                    Text("✓")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 40)
                        .background(.green, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    captureSession.reset()
                    stopIdleTimer()
                    state = .ready
                } label: {
                    Text("✗")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.gray)
                        .frame(width: 56, height: 40)
                        .background(Color(.darkGray), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - Saved State

    private var savedView: some View {
        VStack(spacing: 10) {
            Spacer()
            ZStack {
                Circle()
                    .fill(.green.opacity(0.15))
                    .frame(width: 60, height: 60)
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.green)
            }
            Text("Saved")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            Spacer()
        }
    }

    // MARK: - Connecting State

    private var connectingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .scaleEffect(1.3)
            Text("Connecting via iPhone...")
                .font(.system(size: 12))
                .foregroundStyle(.gray)
            Spacer()
        }
    }

    // MARK: - Voice Interactive State

    private var voiceInteractiveView: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(voiceSession.state == .listening ? .green : .vomoPurple)
                    .frame(width: 6, height: 6)
                Text(voiceSession.state == .responding ? "SPEAKING" : "LISTENING")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(voiceSession.state == .responding ? .vomoPurple : .green)
                Spacer()
                exitButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            voiceTranscriptView

            if voiceSession.state == .responding {
                HStack(spacing: 2) {
                    ForEach(0..<6, id: \.self) { i in
                        WaveformBar(index: i, isActive: true, color: .vomoPurple)
                    }
                }
                .frame(height: 16)
                .padding(.bottom, 4)
            } else {
                Text("TAP → PTT mode")
                    .font(.system(size: 8))
                    .foregroundStyle(.gray.opacity(0.4))
                    .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Voice PTT State

    private var voicePTTView: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.blue)
                    .frame(width: 6, height: 6)
                Text("PTT READY")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.blue)
                Spacer()
                exitButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            voiceTranscriptView

            // Hold-to-talk button
            pttTalkButton(isActive: false)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Voice PTT Talking State

    private var voicePTTTalkingView: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                Text("TRANSMITTING")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.red)
                Spacer()
                exitButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer()

            HStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { i in
                    WaveformBar(index: i, isActive: true, color: .red)
                }
            }
            .frame(height: 40)

            Spacer()

            // Release area
            pttTalkButton(isActive: true)
                .padding(.bottom, 4)
        }
    }

    // MARK: - PTT Talk Button (hold to talk)

    private func pttTalkButton(isActive: Bool) -> some View {
        Text(isActive ? "Release to send" : "Hold to talk")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(isActive ? .red : .blue, in: Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if state == .voicePTT {
                            voiceSession.startPTT()
                            state = .voicePTTTalking
                        }
                    }
                    .onEnded { _ in
                        if state == .voicePTTTalking {
                            voiceSession.stopPTT()
                            state = .voicePTT
                        }
                    }
            )
            .padding(.horizontal, 12)
    }

    // MARK: - No Phone State

    private var noPhoneView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "iphone.slash")
                .font(.system(size: 28))
                .foregroundStyle(.yellow)
            Text("iPhone needed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.yellow)
            Text("Voice AI requires your\niPhone nearby")
                .font(.system(size: 10))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
            Spacer()
            Text("Quick capture still works ↑")
                .font(.system(size: 9))
                .foregroundStyle(.gray.opacity(0.5))
                .padding(.bottom, 8)
        }
    }

    // MARK: - Shared Voice Transcript

    private var voiceTranscriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(voiceSession.transcript.turns) { turn in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(turn.role == .user ? "You" : "AI")
                                .font(.system(size: 8))
                                .foregroundStyle(turn.role == .user ? .gray : .vomoPurple)
                            Text(turn.text)
                                .font(.system(size: 10))
                                .foregroundStyle(turn.role == .user ? .white.opacity(0.85) : .gray)
                        }
                        .padding(.horizontal, 12)
                    }
                    if !voiceSession.transcript.currentAssistantText.isEmpty {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("AI")
                                .font(.system(size: 8))
                                .foregroundStyle(.vomoPurple)
                            Text(voiceSession.transcript.currentAssistantText)
                                .font(.system(size: 10))
                                .foregroundStyle(.gray)
                        }
                        .padding(.horizontal, 12)
                    }
                    Color.clear.frame(height: 1).id("vbottom")
                }
            }
            .frame(maxHeight: .infinity)
            .onChange(of: voiceSession.transcript.turns.count) {
                withAnimation { proxy.scrollTo("vbottom", anchor: .bottom) }
            }
            .onChange(of: voiceSession.transcript.currentAssistantText) {
                withAnimation { proxy.scrollTo("vbottom", anchor: .bottom) }
            }
        }
    }

    // MARK: - Exit Button

    private var exitButton: some View {
        Button {
            if let next = state.onSwipeDown() {
                transition(to: next)
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.gray)
                .frame(width: 24, height: 24)
                .background(Color(.darkGray), in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Gestures

    private func handleTap() {
        guard let next = state.onTap() else { return }
        transition(to: next)
    }

    private func handleLongPress() {
        guard let next = state.onLongPress() else { return }
        transition(to: next)
    }

    private func handleSwipeDown() {
        guard let next = state.onSwipeDown() else { return }
        transition(to: next)
    }

    private func handleWristLower() {
        guard let next = state.onWristLower() else { return }
        transition(to: next)
    }

    // MARK: - State Transitions

    private func transition(to newState: WatchAppState) {
        let oldState = state

        // Exit actions
        switch oldState {
        case .recording:
            captureSession.pause()
            wristMotion.stopMonitoring()
        case .voiceInteractive, .voicePTT, .voicePTTTalking:
            if !newState.isVoiceAI {
                voiceSession.disconnect()
                connectivity.voiceProxy = nil
            }
        case .paused:
            stopIdleTimer()
        case .saveConfirm:
            stopIdleTimer()
        default:
            break
        }

        state = newState

        // Enter actions
        switch newState {
        case .recording:
            if oldState == .paused {
                Task { await captureSession.resume() }
            } else {
                Task { await captureSession.start() }
            }
            wristMotion.startMonitoring()

        case .paused:
            startIdleTimer(seconds: 60) { saveAndReturn() }

        case .saveConfirm:
            saveCountdown = 5
            startIdleTimer(seconds: 5) { saveAndReturn() }

        case .connecting:
            connectivity.voiceProxy = voiceSession
            startVoiceAI()

        case .voicePTT:
            if oldState == .voiceInteractive {
                voiceSession.switchToPTT()
            }

        case .voiceInteractive:
            if oldState == .voicePTT || oldState == .voicePTTTalking {
                voiceSession.switchToInteractive()
            }

        case .saved:
            Task {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run {
                    captureSession.reset()
                    state = .ready
                }
            }

        case .ready:
            if oldState == .saveConfirm {
                captureSession.reset()
            } else if oldState.isVoiceAI {
                voiceSession.disconnect()
                connectivity.voiceProxy = nil
            }

        default:
            break
        }
    }

    // MARK: - Voice AI

    private func startVoiceAI() {
        guard connectivity.isPhoneReachable else {
            state = .noPhone
            return
        }
        voiceSession.connect(recordingMode: .conversational)

        Task {
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(100))
                switch voiceSession.state {
                case .connected, .listening:
                    await MainActor.run {
                        if self.state == .connecting {
                            self.state = .voiceInteractive
                        }
                    }
                    return
                case .error:
                    await MainActor.run {
                        self.state = .noPhone
                    }
                    return
                default:
                    continue
                }
            }
            await MainActor.run {
                if self.state == .connecting {
                    self.state = .noPhone
                }
            }
        }
    }

    // MARK: - Save

    private func saveAndReturn() {
        guard captureSession.hasContent else {
            captureSession.reset()
            state = .ready
            return
        }

        let (title, content) = captureSession.formatForSave()
        connectivity.saveTranscript(
            title: title,
            content: content,
            folder: "Assets/Transcriptions",
            type: "quick",
            date: Date()
        )
        state = .saved
    }

    // MARK: - Timers

    private func startIdleTimer(seconds: Int, action: @escaping () -> Void) {
        stopIdleTimer()
        idleSeconds = seconds
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                idleSeconds -= 1
                if state == .saveConfirm { saveCountdown = idleSeconds }
                if idleSeconds <= 0 {
                    stopIdleTimer()
                    action()
                }
            }
        }
    }

    private func stopIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func cleanup() {
        captureSession.stop()
        voiceSession.disconnect()
        wristMotion.stopMonitoring()
        stopIdleTimer()
        connectivity.voiceProxy = nil
    }
}

// MARK: - Waveform Bar

struct WaveformBar: View {
    let index: Int
    let isActive: Bool
    var color: Color = .red

    @State private var height: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 4, height: height)
            .opacity(isActive ? 0.6 + Double.random(in: 0...0.4) : 0.3)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.3 + Double(index) * 0.05)
                    .repeatForever(autoreverses: true)
                ) {
                    height = CGFloat.random(in: 15...55)
                }
            }
    }
}
