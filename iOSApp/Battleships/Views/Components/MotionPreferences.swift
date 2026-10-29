import Foundation
import MediaAccessibility
import Observation

/// System settings that decide how much the app animates, kept current as they change: Low Power
/// Mode, which pauses purely decorative motion to save battery, Dim Flashing Lights, and the thermal
/// state, which slows looping ambience when the device is warm. `MotionPolicy` folds them together.
@MainActor
@Observable
final class MotionPreferences {
    static let shared = MotionPreferences()

    private(set) var isLowPowerModeEnabled: Bool
    private(set) var dimsFlashingLights: Bool
    /// `.serious` and `.critical` drop the motion policy to the reduced tier.
    private(set) var thermalState: ProcessInfo.ThermalState

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private init() {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        dimsFlashingLights = MADimFlashingLightsEnabled()
        thermalState = ProcessInfo.processInfo.thermalState
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                }
            },
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.thermalState = ProcessInfo.processInfo.thermalState
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
