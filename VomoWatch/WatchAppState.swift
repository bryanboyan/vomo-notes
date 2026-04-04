import SwiftUI

enum WatchAppState: Equatable {
    case ready
    case recording
    case paused
    case saveConfirm
    case connecting
    case voiceInteractive
    case voicePTT
    case voicePTTTalking
    case noPhone
    case saved

    // MARK: - Transition functions

    /// Returns the next state after a tap gesture, or nil if tap has no effect.
    func onTap() -> WatchAppState? {
        switch self {
        case .ready:            return .recording
        case .recording:        return .paused
        case .paused:           return .recording
        case .saveConfirm:      return nil  // buttons handle this
        case .connecting:       return nil
        case .voiceInteractive: return .voicePTT
        case .voicePTT:         return .voiceInteractive
        case .voicePTTTalking:  return nil
        case .noPhone:          return .ready
        case .saved:            return nil
        }
    }

    /// Returns the next state after a long-press gesture, or nil if long-press has no effect.
    func onLongPress() -> WatchAppState? {
        switch self {
        case .ready:            return .connecting
        case .recording:        return nil
        case .paused:           return .saveConfirm
        case .saveConfirm:      return nil
        case .connecting:       return nil
        case .voiceInteractive: return nil
        case .voicePTT:         return nil
        case .voicePTTTalking:  return nil
        case .noPhone:          return nil
        case .saved:            return nil
        }
    }

    /// Returns the next state after a swipe-down gesture, or nil if swipe-down has no effect.
    func onSwipeDown() -> WatchAppState? {
        switch self {
        case .ready:            return nil
        case .recording:        return .paused
        case .paused:           return nil
        case .saveConfirm:      return .ready
        case .connecting:       return nil
        case .voiceInteractive: return .ready
        case .voicePTT:         return .ready
        case .voicePTTTalking:  return .ready
        case .noPhone:          return .ready
        case .saved:            return nil
        }
    }

    /// Returns the next state when the wrist is lowered, or nil if wrist-lower has no effect.
    func onWristLower() -> WatchAppState? {
        switch self {
        case .ready:            return nil
        case .recording:        return .paused
        case .paused:           return nil
        case .saveConfirm:      return nil
        case .connecting:       return nil
        case .voiceInteractive: return nil
        case .voicePTT:         return nil
        case .voicePTTTalking:  return nil
        case .noPhone:          return nil
        case .saved:            return nil
        }
    }

    // MARK: - Computed UI properties

    var borderColor: Color {
        switch self {
        case .ready:            return .clear
        case .recording:        return .red
        case .paused:           return .yellow
        case .saveConfirm:      return .green
        case .connecting:       return .clear
        case .voiceInteractive: return .green
        case .voicePTT:         return .blue
        case .voicePTTTalking:  return .red
        case .noPhone:          return .clear
        case .saved:            return .clear
        }
    }

    var isVoiceAI: Bool {
        switch self {
        case .voiceInteractive, .voicePTT, .voicePTTTalking:
            return true
        default:
            return false
        }
    }

    var isQuickCapture: Bool {
        switch self {
        case .ready, .recording, .paused, .saveConfirm, .saved:
            return true
        default:
            return false
        }
    }
}
