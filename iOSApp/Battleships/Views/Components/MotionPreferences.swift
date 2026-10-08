import Foundation
import MediaAccessibility
import Observation

/// System settings that decide how much the app animates, kept current as they change: Low Power
/// Mode, which pauses purely decorative motion to save battery, and Dim Flashing Lights.
@MainActor
@Observable
final class MotionPreferences {
    static let shared = MotionPreferences()

    private(set) var isLowPowerModeEnabled: Bool
    private(set) var dimsFlashingLights: Bool

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private init() {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        dimsFlashingLights = MADimFlashingLightsEnabled()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                }
            },
            center.addObserver(
                forName: Notification.Name(kMADimFlashingLightsChangedNotification as String),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dimsFlashingLights = MADimFlashingLightsEnabled()
                }
            },
        ]
    }
}
