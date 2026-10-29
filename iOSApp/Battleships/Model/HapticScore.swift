import Foundation

/// A haptic pattern as data: taps and rumbles at times relative to the start of its event, timed
/// with the `Timing` tokens so the rumble, the picture and the sound share a frame.
/// ``HapticEngine`` turns a score into a Core Haptics pattern; the UIKit generators approximate it.
struct HapticScore: Sendable, Equatable {
    struct Event: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// A single tap.
            case transient
            /// A rumble held for `duration`.
            case continuous
        }

        let kind: Kind
        /// Seconds after the start of the score.
        let time: TimeInterval
        /// How long a continuous event lasts; 0 for a transient.
        let duration: TimeInterval
        /// 0…1.
        let intensity: Double
        /// 0 (round, soft) … 1 (crisp, hard).
        let sharpness: Double

        static func transient(at time: TimeInterval, intensity: Double, sharpness: Double) -> Event {
            Event(kind: .transient, time: time, duration: 0, intensity: intensity, sharpness: sharpness)
        }

        static func continuous(from time: TimeInterval, for duration: TimeInterval, intensity: Double, sharpness: Double) -> Event {
            Event(kind: .continuous, time: time, duration: duration, intensity: intensity, sharpness: sharpness)
        }
    }

    /// In playing order.
    let events: [Event]

    init(events: [Event]) {
        self.events = events.sorted { $0.time < $1.time }
    }

    /// When the last event ends.
    var duration: TimeInterval {
        events.reduce(0) { max($0, $1.time + $1.duration) }
    }

    /// Every intensity multiplied by `strength` (the Haptic Strength setting), kept within 0…1.
    func scaled(by strength: Double) -> HapticScore {
        HapticScore(events: events.map { event in
            Event(
                kind: event.kind,
                time: event.time,
                duration: event.duration,
                intensity: min(1, max(0, event.intensity * strength)),
                sharpness: event.sharpness
            )
        })
    }

    /// The same score played `factor` times slower (2 is twice as long), for slow motion.
    func stretched(by factor: Double) -> HapticScore {
        HapticScore(events: events.map { event in
            Event(
                kind: event.kind,
                time: event.time * factor,
                duration: event.duration * factor,
                intensity: event.intensity,
                sharpness: event.sharpness
            )
        })
    }

    /// The score for `event`, or `nil` for an event that deliberately has no haptic.
    static func score(for event: FeedbackEvent) -> HapticScore? {
        switch event {
        case .select:
            // One light tap.
            return HapticScore(events: [.transient(at: 0, intensity: 0.3, sharpness: 0.5)])
        case .aim:
            // A crisp lock-on tick.
            return HapticScore(events: [.transient(at: 0, intensity: 0.45, sharpness: 0.9)])
        case .place:
            // A plunk: a tap with a little weight under it.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.55, sharpness: 0.4),
                .continuous(from: 0.01, for: 0.04, intensity: 0.3, sharpness: 0.1),
            ])
        case .invalid:
            // A shudder: two rough blips, like the buzz.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.6, sharpness: 0.3),
                .continuous(from: 0, for: 0.08, intensity: 0.45, sharpness: 0.2),
                .transient(at: 0.14, intensity: 0.6, sharpness: 0.3),
                .continuous(from: 0.14, for: 0.08, intensity: 0.45, sharpness: 0.2),
            ])
        case .fire:
            // Sharp recoil, then a short rumble as the gun settles.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.9, sharpness: 0.8),
                .continuous(from: 0.015, for: 0.05, intensity: 0.5, sharpness: 0.25),
            ])
        case .incoming:
            // The enemy's guns, far away.
            return HapticScore(events: [.transient(at: 0, intensity: 0.4, sharpness: 0.3)])
        case .miss:
            // A soft thud and a short, low wash.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.45, sharpness: 0.2),
                .continuous(from: 0.01, for: 0.09, intensity: 0.3, sharpness: 0.1),
            ])
        case .hit:
            return hit
        case .sunk:
            // The hit, then three secondaries going off down the hull (never faster than the
            // chain detonation on screen), then a long, low rumble as she goes.
            return HapticScore(events: hit.events + [
                .transient(at: Timing.secondaryStep, intensity: 0.8, sharpness: 0.5),
                .transient(at: Timing.secondaryStep * 2, intensity: 0.65, sharpness: 0.4),
                .transient(at: Timing.secondaryStep * 3, intensity: 0.5, sharpness: 0.3),
                .continuous(from: Timing.secondaryStep * 3, for: 0.4, intensity: 0.4, sharpness: 0.05),
                .continuous(from: Timing.secondaryStep * 3 + 0.4, for: 0.5, intensity: 0.2, sharpness: 0.05),
            ])
        case .victory:
            // Four rising taps on the fanfare's notes, then a warm hold on the chord.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.6, sharpness: 0.4),
                .transient(at: 0.13, intensity: 0.7, sharpness: 0.5),
                .transient(at: 0.26, intensity: 0.8, sharpness: 0.6),
                .transient(at: 0.39, intensity: 1, sharpness: 0.7),
                .continuous(from: 0.39, for: 0.5, intensity: 0.5, sharpness: 0.3),
            ])
        case .defeat:
            // Falling taps on the lament's notes, then a low drone.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.7, sharpness: 0.3),
                .transient(at: 0.28, intensity: 0.6, sharpness: 0.25),
                .transient(at: 0.56, intensity: 0.5, sharpness: 0.2),
                .transient(at: 0.86, intensity: 0.8, sharpness: 0.1),
                .continuous(from: 0.86, for: 0.7, intensity: 0.35, sharpness: 0.05),
            ])
        case .lift:
            // A soft click as the ship comes up.
            return HapticScore(events: [.transient(at: 0, intensity: 0.35, sharpness: 0.5)])
        case .rotate:
            // A short ratchet.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.3, sharpness: 0.8),
                .transient(at: 0.035, intensity: 0.35, sharpness: 0.8),
                .transient(at: 0.07, intensity: 0.4, sharpness: 0.8),
            ])
        case .castOff:
            // The horn: a push, then a low hold that eases off.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.6, sharpness: 0.3),
                .continuous(from: 0, for: 0.35, intensity: 0.55, sharpness: 0.15),
                .continuous(from: 0.35, for: 0.35, intensity: 0.4, sharpness: 0.1),
            ])
        case .whistle:
            // A continuous rumble whose sharpness rises for the length of the telegraph.
            let steps = 5
            let step = Timing.whistle / Double(steps)
            return HapticScore(events: (0..<steps).map { index -> Event in
                let progress = Double(index) / Double(steps - 1)
                return .continuous(
                    from: Double(index) * step,
                    for: step,
                    intensity: 0.2 + 0.3 * progress,
                    sharpness: 0.1 + 0.8 * progress
                )
            })
        case .turnSting:
            // Two light taps on the chime's two notes.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.4, sharpness: 0.6),
                .transient(at: 0.12, intensity: 0.5, sharpness: 0.7),
            ])
        case .stamp:
            // One heavy, rigid slam.
            return HapticScore(events: [.transient(at: 0, intensity: 1, sharpness: 0.95)])
        case .finalBlow:
            // The hit, stretched by the finale's slow motion.
            return hit.stretched(by: 1 / Timing.finalTimeScale)
        case .matchFound:
            // A sonar ping and its answer.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.5, sharpness: 0.7),
                .transient(at: 0.32, intensity: 0.6, sharpness: 0.8),
            ])
        case .opening:
            // A swell that grows for the length of the brass, then BATTLE STATIONS lands.
            return HapticScore(events: [
                .continuous(from: 0, for: 0.3, intensity: 0.2, sharpness: 0.1),
                .continuous(from: 0.3, for: 0.3, intensity: 0.35, sharpness: 0.15),
                .continuous(from: 0.6, for: 0.3, intensity: 0.5, sharpness: 0.2),
                .transient(at: 0.9, intensity: 0.9, sharpness: 0.5),
            ])
        case .toastSuccess:
            // Two taps, up.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.4, sharpness: 0.5),
                .transient(at: 0.1, intensity: 0.6, sharpness: 0.7),
            ])
        case .toastError:
            // Two taps, down, with a rough edge.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.6, sharpness: 0.4),
                .transient(at: 0.1, intensity: 0.5, sharpness: 0.2),
                .continuous(from: 0.1, for: 0.08, intensity: 0.4, sharpness: 0.15),
            ])
        case .tick:
            // The faintest tap, for a counter step.
            return HapticScore(events: [.transient(at: 0, intensity: 0.15, sharpness: 0.6)])
        case .lastShip:
            // One ominous, round thud with a low tail.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.7, sharpness: 0.2),
                .continuous(from: 0.02, for: 0.4, intensity: 0.35, sharpness: 0.05),
            ])
        case .streak:
            // Three quick ticks, rising.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.3, sharpness: 0.5),
                .transient(at: 0.06, intensity: 0.4, sharpness: 0.65),
                .transient(at: 0.12, intensity: 0.5, sharpness: 0.8),
            ])
        }
    }

    /// A hard strike, then 180 ms of rumble that dies away in steps.
    private static let hit = HapticScore(events: [
        .transient(at: 0, intensity: 1, sharpness: 0.6),
        .continuous(from: 0.02, for: 0.06, intensity: 0.7, sharpness: 0.2),
        .continuous(from: 0.08, for: 0.06, intensity: 0.45, sharpness: 0.15),
        .continuous(from: 0.14, for: 0.06, intensity: 0.25, sharpness: 0.1),
    ])
}
