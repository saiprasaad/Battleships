import Foundation
import MediaAccessibility
import Observation
import UIKit

/// System settings and app state that decide how much the app animates, kept current as they
/// change: Low Power Mode, which pauses purely decorative motion to save battery, Dim Flashing
/// Lights, the thermal state, which slows looping ambience when the device is warm, whether
/// VoiceOver is running, whether the app is in the foreground, and the screen's refresh rate.
/// `MotionPolicy` folds them together.
@MainActor
@Observable
final class MotionPreferences {
    static let shared = MotionPreferences()

    private(set) var isLowPowerModeEnabled: Bool
    private(set) var dimsFlashingLights: Bool
    /// `.serious` drops the motion policy to the reduced tier; `.critical` holds it still.
    private(set) var thermalState: ProcessInfo.ThermalState
    private(set) var isVoiceOverRunning: Bool
    /// Whether the app is in the foreground. `BattleshipsApp` sets it from `scenePhase`; while it
    /// is false every screen is in the still tier.
    var isActive = true
    /// The refresh rate of the screen the app is on, from `noteScreen(maximumFramesPerSecond:)`.
    /// Effects never run faster than 60 whatever it is; a slower screen caps them lower.
    private(set) var maxFramesPerSecond = 60

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private init() {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        dimsFlashingLights = MADimFlashingLightsEnabled()
        thermalState = ProcessInfo.processInfo.thermalState
        isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
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
            center.addObserver(forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
                }
            },
        ]
    }

    /// Records the refresh rate of the screen the app is on. The app calls it with the key window
    /// scene's `screen.maximumFramesPerSecond` when a scene connects or moves to another screen;
    /// `UIScreen.main` is never read.
    func noteScreen(maximumFramesPerSecond: Int) {
        maxFramesPerSecond = max(1, maximumFramesPerSecond)
    }
}
