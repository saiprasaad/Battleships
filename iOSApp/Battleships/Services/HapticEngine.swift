import CoreHaptics

/// Plays each event's ``HapticScore`` on Core Haptics, so a hit thuds and rumbles rather than just
/// clicks. Where Core Haptics isn't available (iPad, the simulator) or fails, the UIKit generators
/// in ``Haptics`` say what happened instead.
@MainActor
final class HapticEngine: FeedbackPlayer {
    private let isEnabled: @MainActor () -> Bool
    private let strength: @MainActor () -> Double
    private let fallback: Haptics
    private let supportsHaptics: Bool
    private var engine: CHHapticEngine?
    /// The engine has stopped (idle, interrupted, or reset) and must be started before it plays.
    private var needsStart = true
    /// Patterns already built, at the strength they were built for.
    private var patterns: [FeedbackEvent: CHHapticPattern] = [:]
    private var patternStrength = -1.0

    init(isEnabled: @escaping @MainActor () -> Bool, strength: @escaping @MainActor () -> Double) {
        self.isEnabled = isEnabled
        self.strength = strength
        fallback = Haptics(isEnabled: isEnabled)
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    func play(_ event: FeedbackEvent) {
        guard isEnabled() else { return }
        let level = min(1, max(0, strength()))
        guard level > 0 else { return }
        guard supportsHaptics else {
            playFallback(event, strength: level)
            return
        }
        guard let score = HapticScore.score(for: event) else { return }
        do {
            let engine = try runningEngine()
            let pattern = try makePattern(for: event, score: score, strength: level)
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Core Haptics is a luxury: the generators still say what happened.
            needsStart = true
            playFallback(event, strength: level)
        }
    }

    private func playFallback(_ event: FeedbackEvent, strength: Double) {
        // Turned down, the smallest ticks go first; the generators can't play them any softer.
        if strength < 0.5, event == .tick || event == .select { return }
        fallback.play(event)
    }

    /// The engine, created on first use and started whenever it has stopped since.
    private func runningEngine() throws -> CHHapticEngine {
        let engine: CHHapticEngine
        if let existing = self.engine {
            engine = existing
        } else {
            engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
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

    /// The system reset the haptic server: this engine and every player made from it are gone,
    /// so the next play makes a new one.
    private func engineDidReset() {
        engine = nil
        needsStart = true
    }

    /// The engine stopped (idle shutdown, an interruption, the app suspended): start it next time.
    private func engineDidStop() {
        needsStart = true
    }

    private func makePattern(for event: FeedbackEvent, score: HapticScore, strength: Double) throws -> CHHapticPattern {
        if strength != patternStrength {
            patterns = [:]
            patternStrength = strength
        }
        if let pattern = patterns[event] {
            return pattern
        }
        let events = score.scaled(by: strength).events.map { cue -> CHHapticEvent in
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
        patterns[event] = pattern
        return pattern
    }
}
