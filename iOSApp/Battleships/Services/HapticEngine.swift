import CoreHaptics
import UIKit

/// Plays each event's ``HapticScore`` on Core Haptics, so a hit thuds and rumbles rather than just
/// clicks. Where Core Haptics isn't available (iPad, the simulator) or fails, the UIKit generators
/// in ``Haptics`` say what happened instead. Scores are shaped by the play's `FeedbackVariation`,
/// scaled by the Haptic Strength setting, capped under Reduce Motion, and scheduled on the
/// engine's own clock when the play carries a delay, so a landing meets its frame.
@MainActor
final class HapticEngine: FeedbackPlayer {
    private let isEnabled: @MainActor () -> Bool
    private let strength: @MainActor () -> Double
    private let fallback: Haptics
    private let supportsHaptics: Bool
    private var engine: CHHapticEngine?
    /// The engine has stopped (rested, interrupted, or reset) and must be started before it plays.
    private var needsStart = true
    /// Patterns already built, keyed by the event and everything that shaped them.
    private var patterns: [PatternKey: CHHapticPattern] = [:]

    /// What tells one built pattern from another: the event, the variation's shape, the level
    /// (intensity × strength, in 32 steps) and the Reduce Motion cap.
    private struct PatternKey: Hashable {
        let event: FeedbackEvent
        let isMine: Bool
        let isFinal: Bool
        let count: Int
        let level: Int
        let reducesMotion: Bool
    }

    init(fallback: Haptics, isEnabled: @escaping @MainActor () -> Bool, strength: @escaping @MainActor () -> Double) {
        self.fallback = fallback
        self.isEnabled = isEnabled
        self.strength = strength
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    func play(_ event: FeedbackEvent) {
        play(event, variation: .default)
    }

    func play(_ event: FeedbackEvent, variation: FeedbackVariation) {
        guard isEnabled() else { return }
        let level = min(1, max(0, strength() * variation.intensity))
        guard level > 0 else { return }
        guard supportsHaptics else {
            playFallback(event, variation: variation, level: level)
            return
        }
        guard HapticScore.score(for: event, variation: variation) != nil else { return }
        do {
            let engine = try runningEngine()
            let pattern = try makePattern(for: event, variation: variation, level: level)
            let player = try engine.makePlayer(with: pattern)
            let start: TimeInterval = variation.delay > 0 ? engine.currentTime + variation.delay : CHHapticTimeImmediate
            try player.start(atTime: start)
        } catch {
            // Core Haptics is a luxury: the generators still say what happened.
            needsStart = true
            playFallback(event, variation: variation, level: level)
        }
    }

    /// Starts the engine early, so the first cue of a battle or placement has no latency.
    func prepare() {
        fallback.prepare()
        guard supportsHaptics, isEnabled() else { return }
        _ = try? runningEngine()
    }

    /// Stops the engine: the screen is gone, or the app is in the background.
    func rest() {
        guard let engine else { return }
        needsStart = true
        engine.stop(completionHandler: nil)
    }

    private func playFallback(_ event: FeedbackEvent, variation: FeedbackVariation, level: Double) {
        // Turned down, the smallest ticks go first; the generators can't play them any softer.
        if level < 0.5, event == .tick || event == .select || event == .navigate { return }
        fallback.play(event, variation: variation)
    }

    /// The engine, created on first use and started whenever it has stopped since.
    private func runningEngine() throws -> CHHapticEngine {
        let engine: CHHapticEngine
        if let existing = self.engine {
            engine = existing
        } else {
            engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = false
            engine.playsHapticsOnly = true
            engine.resetHandler = { @Sendable [weak self] in
                Task { @MainActor in self?.engineDidReset() }
            }
            engine.stoppedHandler = { @Sendable [weak self] _ in
                Task { @MainActor in self?.engineDidStop() }
            }
            self.engine = engine
            needsStart = true
        }
        if needsStart {
            try engine.start()
            needsStart = false
        }
        return engine
    }

    /// The system reset the haptic server: this engine, its players and its patterns are gone,
    /// so the next play makes new ones.
    private func engineDidReset() {
        engine = nil
        patterns = [:]
        needsStart = true
    }

    /// The engine stopped (rested, an interruption, the app suspended): start it next time.
    private func engineDidStop() {
        needsStart = true
    }

    private func makePattern(for event: FeedbackEvent, variation: FeedbackVariation, level: Double) throws -> CHHapticPattern {
        let reducesMotion = UIAccessibility.isReduceMotionEnabled
        let key = PatternKey(
            event: event,
            isMine: variation.isMine,
            isFinal: variation.isFinal,
            count: min(max(variation.count, 0), 20),
            level: Int((level * 32).rounded()),
            reducesMotion: reducesMotion
        )
        if let pattern = patterns[key] {
            return pattern
        }
        // The variation shapes the score, the strength setting scales it, Reduce Motion caps it,
        // and rendering turns its ramps into short flat steps: one pattern, no parameter curves.
        var score = HapticScore.score(for: event, variation: variation) ?? HapticScore(events: [])
        score = score.scaled(by: min(1, max(0, strength())))
        if reducesMotion {
            score = score.reduceMotionCapped(maxIntensity: event == .whistle ? 0.35 : 0.7)
        }
        let events = score.rendered().events.map { cue -> CHHapticEvent in
            let parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(cue.intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(cue.sharpness)),
            ]
            switch cue.kind {
            case .transient:
                return CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: cue.time)
            case .continuous:
                return CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: parameters,
                    relativeTime: cue.time,
                    duration: cue.duration
                )
            }
        }
        let pattern = try CHHapticPattern(events: events, parameters: [])
        if patterns.count > 64 {
            patterns = [:]
        }
        patterns[key] = pattern
        return pattern
    }
}
