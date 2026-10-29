import Foundation
import SwiftUI

/// How much the app may move right now, from the system's accessibility and power settings, the
/// app's own state (foreground, left alone) and the player's Effects settings. Read it from the
/// environment: `@Environment(\.motionPolicy)`. It is set once, at the root, by
/// `motionPolicy(settings:)`, so every screen and sheet sees the same answer; `motionIdle(_:)`
/// lowers it for a subtree that has been left alone.
struct MotionPolicy: Equatable, Sendable {
    /// From the least motion to the most. Compares by raw value, so `tier < .full` reads naturally.
    enum Tier: Int, Comparable, Sendable {
        case still, reduced, full

        static func < (lhs: Tier, rhs: Tier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var tier: Tier
    /// White cores, muzzle flashes, lightning, light sweeps, chromatic splits may be drawn: only in
    /// the full tier, and never under Dim Flashing Lights or with the Flashes setting off.
    var allowsFlashes: Bool
    /// Boards and the HUD may jolt: only in the full tier, with the Screen Shake setting on.
    var allowsShake: Bool
    /// 0…1, from the Haptic Strength setting (0 = haptics off).
    var hapticStrength: Double
    var isVoiceOverRunning: Bool
    /// The slowest frame interval looping ambience should use (1/30 normally; 1/20 in the reduced tier
    /// or when the device is warm; the still tier pauses loops instead).
    var ambientFrameInterval: TimeInterval
    /// Metal shaders may run (false only when the device is critically hot). Shaders also draw in
    /// the still tier, frozen.
    var allowsShaders: Bool
    /// Openings, finales, welcome and deploy sequences collapse to a ≤ 0.3 s fade with every control
    /// available at once: under VoiceOver, the still tier, or Effects = Minimal.
    var collapsesSequences: Bool
    /// Clocks hold at a fixed, pretty phase (screenshots, and the still tier).
    var freezesClocks: Bool
    /// The fastest any effect redraws: 60 in the full tier whatever the display (ProMotion never
    /// runs effects at 120), 30 otherwise, and never more than the screen can show.
    var maxFrameRate: Double

    init(
        tier: Tier,
        allowsFlashes: Bool,
        allowsShake: Bool,
        hapticStrength: Double,
        isVoiceOverRunning: Bool,
        ambientFrameInterval: TimeInterval,
        allowsShaders: Bool = true,
        collapsesSequences: Bool? = nil,
        freezesClocks: Bool = false,
        maxFrameRate: Double? = nil
    ) {
        self.tier = tier
        self.allowsFlashes = allowsFlashes
        self.allowsShake = allowsShake
        self.hapticStrength = hapticStrength
        self.isVoiceOverRunning = isVoiceOverRunning
        self.ambientFrameInterval = ambientFrameInterval
        self.allowsShaders = allowsShaders
        self.collapsesSequences = collapsesSequences ?? (tier == .still || isVoiceOverRunning)
        self.freezesClocks = freezesClocks
        self.maxFrameRate = maxFrameRate ?? (tier == .full ? 60 : 30)
    }

    // MARK: What follows from the tier

    /// The spec's name for `allowsFlashes`.
    var flashes: Bool { allowsFlashes }
    /// The spec's name for `allowsShake`.
    var shakes: Bool { allowsShake }
    /// Particle fields may be drawn: everything but the still tier.
    var allowsParticles: Bool { tier != .still }
    /// Backdrops may follow the device's tilt: the full tier only, and never under VoiceOver.
    var allowsParallax: Bool { tier == .full && !isVoiceOverRunning }
    /// How many particles may be alive at once, app-wide.
    var particleBudget: Int {
        switch tier {
        case .full: 600
        case .reduced: 240
        case .still: 0
        }
    }
    /// Clocks show their end state and never tick: the still tier, or frozen clocks.
    var holdsStill: Bool { tier == .still || freezesClocks }
    /// Looping decoration holds still (the still tier, or frozen clocks).
    var loopsHoldStill: Bool { holdsStill }
    /// Bursts, shells, fireworks: the frame interval for one-shot effects.
    var effectsInterval: TimeInterval { 1 / max(1, maxFrameRate) }
    /// The water's frame interval, or nil when it should hold still.
    var waterInterval: TimeInterval? {
        switch tier {
        case .full: 1 / 24
        case .reduced: 1 / 12
        case .still: nil
        }
    }
    /// Radar, waves, halos: the frame interval for looping ambience, or nil when it should hold still.
    var ambientInterval: TimeInterval? {
        switch tier {
        case .full: 1 / 30
        case .reduced: 1 / 15
        case .still: nil
        }
    }
    /// Backdrop drift, bobbing ships, smoke: the frame interval for scenery, or nil when it should hold still.
    var sceneryInterval: TimeInterval? {
        switch tier {
        case .full: 1 / 20
        case .reduced: 1 / 10
        case .still: nil
        }
    }

    /// How long a one-shot sequence runs under this policy: as written in the full tier, 0.7× in the
    /// reduced tier, and 0 in the still tier (it shows its end state at once).
    func duration(_ full: TimeInterval) -> TimeInterval {
        switch tier {
        case .full: full
        case .reduced: full * 0.7
        case .still: 0
        }
    }

    /// This policy for a subtree left alone: the full tier drops to reduced, with everything that
    /// goes with it; a policy that is already reduced or still is unchanged.
    func idled() -> MotionPolicy {
        guard tier == .full else { return self }
        var idled = self
        idled.tier = .reduced
        idled.allowsFlashes = false
        idled.allowsShake = false
        idled.ambientFrameInterval = 1 / 20
        idled.maxFrameRate = min(maxFrameRate, 30)
        return idled
    }

    // MARK: Presets

    static let full = MotionPolicy(
        tier: .full, allowsFlashes: true, allowsShake: true, hapticStrength: 1, isVoiceOverRunning: false, ambientFrameInterval: 1 / 30
    )
    static let reduced = MotionPolicy(
        tier: .reduced, allowsFlashes: false, allowsShake: false, hapticStrength: 1, isVoiceOverRunning: false, ambientFrameInterval: 1 / 20
    )
    static let still = MotionPolicy(
        tier: .still, allowsFlashes: false, allowsShake: false, hapticStrength: 1, isVoiceOverRunning: false, ambientFrameInterval: 1 / 20
    )
    /// Full visuals with frozen clocks: what `ScreenshotTests` render. Clocks show their end state
    /// or pretty phase, sequences still play (so the stills show them landed, not collapsed).
    static let screenshot = MotionPolicy(
        tier: .full,
        allowsFlashes: true,
        allowsShake: true,
        hapticStrength: 1,
        isVoiceOverRunning: false,
        ambientFrameInterval: 1 / 30,
        freezesClocks: true
    )

    // MARK: Resolution

    /// Resolves the policy from everything that feeds it. Pure, so it is unit-testable.
    ///
    /// The one table every tier decision comes from:
    /// - still: Reduce Motion, VoiceOver, Effects = Minimal, a critically hot device, or the app in
    ///   the background (`isActive == false`);
    /// - reduced: Low Power Mode, a seriously hot device, Effects = Reduced, or a screen left alone
    ///   (`isIdle`);
    /// - full otherwise.
    ///
    /// Flashes and shakes are only ever allowed in the full tier, and each has its own switch
    /// besides. Shaders stop only for heat. Sequences collapse under VoiceOver, the still tier and
    /// Effects = Minimal. The frame rate is 60 in the full tier and 30 below it, and never more than
    /// the screen's (`maxFramesPerSecond`); a ProMotion display's 120 is never used for effects.
    static func resolve(
        reduceMotion: Bool,
        lowPower: Bool,
        dimsFlashingLights: Bool,
        thermalState: ProcessInfo.ThermalState,
        voiceOver: Bool,
        effects: EffectsLevel,
        screenShake: Bool,
        flashes: Bool,
        hapticStrength: Double,
        isActive: Bool = true,
        isIdle: Bool = false,
        maxFramesPerSecond: Int = 60
    ) -> MotionPolicy {
        let isCritical = thermalState == .critical
        let isWarm = thermalState == .serious || isCritical
        let tier: Tier
        if reduceMotion || voiceOver || effects == .minimal || isCritical || !isActive {
            tier = .still
        } else if lowPower || isWarm || effects == .reduced || isIdle {
            tier = .reduced
        } else {
            tier = .full
        }
        let screenRate = Double(maxFramesPerSecond > 0 ? maxFramesPerSecond : 60)
        return MotionPolicy(
            tier: tier,
            allowsFlashes: flashes && !dimsFlashingLights && tier == .full,
            allowsShake: screenShake && !reduceMotion && tier == .full,
            hapticStrength: min(max(hapticStrength, 0), 1),
            isVoiceOverRunning: voiceOver,
            ambientFrameInterval: tier == .full && !isWarm ? 1 / 30 : 1 / 20,
            allowsShaders: !isCritical,
            collapsesSequences: voiceOver || tier == .still || effects == .minimal,
            freezesClocks: false,
            maxFrameRate: min(screenRate, tier == .full ? 60 : 30)
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
    /// Dim Flashing Lights, the thermal state, VoiceOver, the app's foreground state and the screen's
    /// refresh rate (`MotionPreferences`) and the player's Effects settings, and hands it to
    /// everything below as `\.motionPolicy`. Applied once, to the root `TabView`.
    func motionPolicy(settings: AppSettings) -> some View {
        modifier(MotionPolicyModifier(settings: settings))
    }

    /// Marks a subtree left alone (a battle after `Timing.idleTier` without interaction): its policy
    /// drops from the full tier to reduced. Any interaction should clear it again.
    func motionIdle(_ isIdle: Bool) -> some View {
        transformEnvironment(\.motionPolicy) { policy in
            if isIdle {
                policy = policy.idled()
            }
        }
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
            voiceOver: isVoiceOverRunning || preferences.isVoiceOverRunning,
            effects: settings.effectsLevel,
            screenShake: settings.screenShakeEnabled,
            flashes: settings.flashesEnabled,
            // The Haptics toggle is the on/off switch; the strength only scales what plays.
            hapticStrength: settings.hapticsEnabled ? settings.hapticStrength : 0,
            isActive: preferences.isActive,
            isIdle: false,
            maxFramesPerSecond: preferences.maxFramesPerSecond
        )
        content.environment(\.motionPolicy, policy)
    }
}
