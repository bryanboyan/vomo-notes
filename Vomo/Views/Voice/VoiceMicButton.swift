import SwiftUI
import UIKit

/// Interactive + PTT mic button — shared across all voice UIs
struct VoiceMicButton: View {
    let state: VoiceChatState
    var inputMode: VoiceInputMode = .interactive
    var isPTTActive: Bool = false
    var size: CGFloat = 56

    // Actions
    var onTap: (() -> Void)?
    var onPTTStart: (() -> Void)?
    var onPTTEnd: (() -> Void)?

    var body: some View {
        if inputMode == .ptt {
            pttButton
        } else {
            interactiveButton
        }
    }

    // MARK: - Interactive

    private var interactiveButton: some View {
        Button {
            onTap?()
        } label: {
            ZStack {
                Circle()
                    .fill(interactiveColor)
                    .frame(width: size, height: size)
                Image(systemName: interactiveIcon)
                    .font(size > 50 ? .title2 : .body)
                    .foregroundStyle(.white)
            }
        }
    }

    private var interactiveColor: Color {
        switch state {
        case .connected, .listening: return .green
        case .responding: return Color.obsidianPurple
        case .error: return .orange
        default: return .gray
        }
    }

    private var interactiveIcon: String {
        switch state {
        case .disconnected, .error: return "mic"
        case .connecting: return "ellipsis"
        case .connected: return "mic.fill"
        case .listening: return "waveform"
        case .responding: return "speaker.wave.2.fill"
        }
    }

    // MARK: - PTT

    private var pttButton: some View {
        let activeSize = size * 1.4
        return ZStack {
            Circle()
                .fill(isPTTActive ? Color.blue : Color.orange)
                .frame(width: isPTTActive ? activeSize : size,
                       height: isPTTActive ? activeSize : size)
            Image(systemName: isPTTActive ? "waveform" : "hand.tap.fill")
                .font(isPTTActive ? .title : (size > 50 ? .title2 : .body))
                .foregroundStyle(.white)
        }
        .animation(.spring(duration: 0.25), value: isPTTActive)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPTTActive {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onPTTStart?()
                    }
                }
                .onEnded { _ in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onPTTEnd?()
                }
        )
    }
}
