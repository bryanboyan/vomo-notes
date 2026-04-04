import Foundation
import CoreMotion

@Observable
final class WristMotionManager {
    var onWristLowered: (() -> Void)?

    private let motionManager = CMMotionManager()
    private let debounceDuration: TimeInterval = 0.3
    private let gravityThreshold: Double = 0.7

    private var wristDownStart: Date?
    private(set) var isMonitoring = false

    func startMonitoring() {
        guard !isMonitoring, motionManager.isDeviceMotionAvailable else { return }
        isMonitoring = true
        motionManager.deviceMotionUpdateInterval = 1.0 / 20.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.processMotion(motion)
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        motionManager.stopDeviceMotionUpdates()
        wristDownStart = nil
    }

    private func processMotion(_ motion: CMDeviceMotion) {
        let isWristDown = motion.gravity.z > gravityThreshold

        if isWristDown {
            if wristDownStart == nil {
                wristDownStart = Date()
            } else if let start = wristDownStart,
                      Date().timeIntervalSince(start) >= debounceDuration {
                wristDownStart = nil
                onWristLowered?()
            }
        } else {
            wristDownStart = nil
        }
    }
}
