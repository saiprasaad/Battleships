import Foundation
import SwiftUI

/// How much the app may move right now, from the system's accessibility and power settings
/// and the player's own Effects settings. Read it from the environment: `@Environment(\.motionPolicy)`.
/// It is set once, at the root, by `motionPolicy(settings:)`, so every screen and sheet sees the same answer.
struct MotionPolicy: Equatable, Sendable {
    /// From the least motion to the most. Compares by raw value, so `tier < .full` reads naturally.
    enum Tier: Int, Comparable, Sendable {
        case still, reduced, full

        static func < (lhs: Tier, rhs: Tier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var tier: Tier
    /// Large or bright flashes may be drawn (off under Dim Flashing Lights and the Flashes setting).
    var allowsFlashes: Bool
    /// Boards and the HUD may jolt (off under Reduce Motion and the Screen Shake setting).
    var allowsShake: Bool
    /// 0…1, from the Haptic Strength setting (0 = haptics off).
    var hapticStrength: Double
    var isVoiceOverRunning: Bool
    /// The slowest frame interval looping ambience should use (1/30 normally; 1/20 in the reduced tier
    /// or when the device is warm; the still tier pauses loops instead).
    var ambientFrameInterval: TimeInterval

    /// Looping decoration holds still (Reduce Motion, Low Power Mode, Effects = Minimal, VoiceOver).
    var loopsHoldStill: Bool { tier == .still }

    static let full = MotionPolicy(
        tier: .full, allowsFlashes: true, allowsShake: true, hapticStrength: 1, isVoiceOverRunning: false, ambientFrameInterval: 1 / 30
    )
    static let reduced = MotionPolicy(
        tier: .reduced, allowsFlashes: false, allowsShake: false, hapticStrength: 1, isVoiceOverRunning: false, ambientFrameInterval: 1 / 20
    )
    static let still = MotionPolicy(
        tier: .still, allowsFlashes: false, allowsShake: false, hapticStrength: 1, isVoiceOverRunning: false, ambientFrameInterval: 1 / 20
    )

    /// Resolves the policy from everything that feeds it. Pure, so it is unit-testable.
    ///
    /// Reduce Motion, VoiceOver or Effects = Minimal give the still tier; Low Power Mode, a serious or
    /// critical thermal state or Effects = Reduced give the reduced tier; otherwise it is full. Flashes
    /// and shakes are only ever allowed in the full tier, and each has its own switch besides.
    static func resolve(
        reduceMotion: Bool,
        lowPower: Bool,
        dimsFlashingLights: Bool,
        thermalState: ProcessInfo.ThermalState,
        voiceOver: Bool,
        effects: EffectsLevel,
        screenShake: Bool,
        flashes: Bool,
        hapticStrength: Double
    ) -> MotionPolicy {
        let isWarm = thermalState == .serious || thermalState == .critical
        let tier: Tier
        if reduceMotion || voiceOver || effects == .minimal {
            tier = .still
        } else if lowPower || isWarm || effects == .reduced {
            tier = .reduced
        } else {
            tier = .full
        }
        return MotionPolicy(
            tier: tier,
            allowsFlashes: flashes && !dimsFlashingLights && tier == .full,
            allowsShake: screenShake && !reduceMotion && tier == .full,
            hapticStrength: min(max(hapticStrength, 0), 1),
            isVoiceOverRunning: voiceOver,
            ambientFrameInterval: tier == .full && !isWarm ? 1 / 30 : 1 / 20
        )
    }
}

private struct MotionPolicyKey: EnvironmentKey {
    static let defaultValue = MotionPolicy.full
}

extension EnvironmentValues {
    /// How much the app may move right now. `.full` until `motionPolicy(settings:)` sets it at the root.
    var motionPolicy: MotionPolicy {
        get { self[MotionPolicyKey.self] }
        set { self[MotionPolicyKey.self] = newValue }
    }
}

extension View {
    /// Resolves the motion policy from Reduce Motion and VoiceOver (the environment), Low Power Mode,
    /// Dim Flashing Lights and the thermal state (`MotionPreferences`) and the player's Effects settings,
    /// and hands it to everything below as `\.motionPolicy`. Applied once, to the root `TabView`.
    func motionPolicy(settings: AppSettings) -> some View {
        modifier(MotionPolicyModifier(settings: settings))
    }
}

/// A modifier rather than a closure, so the environment is read in `body` and the view re-resolves
/// whenever a setting changes.
private struct MotionPolicyModifier: ViewModifier {
    let settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverRunning

    func body(content: Content) -> some View {
        let preferences = MotionPreferences.shared
        let policy = MotionPolicy.resolve(
            reduceMotion: reduceMotion,
            lowPower: preferences.isLowPowerModeEnabled,
            dimsFlashingLights: preferences.dimsFlashingLights,
            thermalState: preferences.thermalState,
            voiceOver: isVoiceOverRunning,
            effects: settings.effectsLevel,
            screenShake: settings.screenShakeEnabled,
            flashes: settings.flashesEnabled,
            // The Haptics toggle is the on/off switch; the strength only scales what plays.
            hapticStrength: settings.hapticsEnabled ? settings.hapticStrength : 0
        )
        content.environment(\.motionPolicy, policy)
    }
}
