import Foundation

/// A haptic pattern as data: taps and rumbles at times relative to the start of its event, timed
/// with the `Timing` tokens so the rumble, the picture and the sound share a frame.
/// ``HapticEngine`` turns a score into a Core Haptics pattern; the UIKit generators approximate it.
struct HapticScore: Sendable, Equatable {
    /// A point on a rumble's intensity or sharpness curve.
    struct ControlPoint: Sendable, Equatable {
        /// Seconds after the start of the continuous event it shapes.
        let time: TimeInterval
        let value: Double
    }

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
        /// 0…1. For a rumble with an intensity curve, its peak.
        let intensity: Double
        /// 0 (round, soft) … 1 (crisp, hard). For a rumble with a sharpness curve, its first value.
        let sharpness: Double
        /// How a rumble's intensity moves over its duration: absolute values at times relative to
        /// its start, linear in between. Empty holds `intensity` throughout.
        let intensityCurve: [ControlPoint]
        /// The same for its sharpness.
        let sharpnessCurve: [ControlPoint]

        init(
            kind: Kind,
            time: TimeInterval,
            duration: TimeInterval,
            intensity: Double,
            sharpness: Double,
            intensityCurve: [ControlPoint] = [],
            sharpnessCurve: [ControlPoint] = []
        ) {
            self.kind = kind
            self.time = time
            self.duration = duration
            self.intensity = intensity
            self.sharpness = sharpness
            self.intensityCurve = intensityCurve
            self.sharpnessCurve = sharpnessCurve
        }

        static func transient(at time: TimeInterval, intensity: Double, sharpness: Double) -> Event {
            Event(kind: .transient, time: time, duration: 0, intensity: intensity, sharpness: sharpness)
        }

        static func continuous(from time: TimeInterval, for duration: TimeInterval, intensity: Double, sharpness: Double) -> Event {
            Event(kind: .continuous, time: time, duration: duration, intensity: intensity, sharpness: sharpness)
        }

        /// A rumble whose intensity and sharpness slide from one value to another over its length.
        static func ramp(
            from time: TimeInterval,
            for duration: TimeInterval,
            intensity: (from: Double, to: Double),
            sharpness: (from: Double, to: Double)
        ) -> Event {
            Event(
                kind: .continuous,
                time: time,
                duration: duration,
                intensity: max(intensity.from, intensity.to),
                sharpness: sharpness.from,
                intensityCurve: [ControlPoint(time: 0, value: intensity.from), ControlPoint(time: duration, value: intensity.to)],
                sharpnessCurve: [ControlPoint(time: 0, value: sharpness.from), ControlPoint(time: duration, value: sharpness.to)]
            )
        }

        /// The intensity `offset` seconds into the event.
        func intensity(at offset: TimeInterval) -> Double {
            Self.value(of: intensityCurve, at: offset) ?? intensity
        }

        /// The sharpness `offset` seconds into the event.
        func sharpness(at offset: TimeInterval) -> Double {
            Self.value(of: sharpnessCurve, at: offset) ?? sharpness
        }

        /// Linear interpolation along `curve`, holding its ends; `nil` for an empty curve.
        private static func value(of curve: [ControlPoint], at offset: TimeInterval) -> Double? {
            guard let first = curve.first, let last = curve.last else { return nil }
            if offset <= first.time { return first.value }
            if offset >= last.time { return last.value }
            for (before, after) in zip(curve, curve.dropFirst()) where offset >= before.time && offset <= after.time {
                let span = after.time - before.time
                guard span > 0 else { return after.value }
                let progress = (offset - before.time) / span
                return before.value + (after.value - before.value) * progress
            }
            return last.value
        }

        /// The same event with every intensity and curve value put through `transform`.
        fileprivate func mappingIntensities(_ transform: (Double) -> Double) -> Event {
            Event(
                kind: kind,
                time: time,
                duration: duration,
                intensity: transform(intensity),
                sharpness: sharpness,
                intensityCurve: intensityCurve.map { ControlPoint(time: $0.time, value: transform($0.value)) },
                sharpnessCurve: sharpnessCurve
            )
        }

        /// The same event with its start moved by `factor` and its length and curves by `lengthFactor`.
        fileprivate func timed(startBy factor: Double, lengthBy lengthFactor: Double) -> Event {
            let stretch = kind == .continuous ? lengthFactor : 1
            return Event(
                kind: kind,
                time: time * factor,
                duration: duration * stretch,
                intensity: intensity,
                sharpness: sharpness,
                intensityCurve: intensityCurve.map { ControlPoint(time: $0.time * stretch, value: $0.value) },
                sharpnessCurve: sharpnessCurve.map { ControlPoint(time: $0.time * stretch, value: $0.value) }
            )
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
            event.mappingIntensities { min(1, max(0, $0 * strength)) }
        })
    }

    /// The same score played `factor` times slower (2 is twice as long), for slow motion.
    func stretched(by factor: Double) -> HapticScore {
        HapticScore(events: events.map { $0.timed(startBy: factor, lengthBy: factor) })
    }

    /// Under Reduce Motion: no intensity above `maxIntensity`, and rumbles cut to 60 %.
    func reduceMotionCapped(maxIntensity: Double = 0.7) -> HapticScore {
        HapticScore(events: events.map { event in
            event.timed(startBy: 1, lengthBy: 0.6).mappingIntensities { min(maxIntensity, $0) }
        })
    }

    /// The score with every curved rumble cut into short flat rumbles that follow its curves, so a
    /// player that knows only flat events (or wants one pattern with no parameter curves) can play it.
    func rendered(step: TimeInterval = 0.03) -> HapticScore {
        var flat: [Event] = []
        for event in events {
            guard event.kind == .continuous, event.duration > 0, step > 0,
                  !event.intensityCurve.isEmpty || !event.sharpnessCurve.isEmpty
            else {
                flat.append(event)
                continue
            }
            let count = max(1, Int((event.duration / step).rounded(.up)))
            let length = event.duration / Double(count)
            for index in 0..<count {
                let offset = Double(index) * length
                let middle = offset + length / 2
                flat.append(.continuous(
                    from: event.time + offset,
                    for: length,
                    intensity: event.intensity(at: middle),
                    sharpness: event.sharpness(at: middle)
                ))
            }
        }
        return HapticScore(events: flat)
    }

    // MARK: The table

    /// Events that deliberately have no haptic: loops.
    static let silentEvents: Set<FeedbackEvent> = [.burning]

    /// The score for `event` as played by default, or `nil` for an event that is deliberately silent.
    static func score(for event: FeedbackEvent) -> HapticScore? {
        score(for: event, variation: .default)
    }

    /// The signature for `event`, shaped by `variation`: `isMine` picks the hit or hitOwn family and
    /// the direction of the last-ship sting, `isFinal` the finale pattern, `count` the number of
    /// shuffle taps and streak ticks, and `intensity` scales the whole score.
    static func score(for event: FeedbackEvent, variation: FeedbackVariation) -> HapticScore? {
        guard !silentEvents.contains(event) else { return nil }
        let base: HapticScore
        switch event {
        case .hit:
            base = variation.isFinal ? finale : (variation.isMine ? hit : hitOwn)
        case .hitOwn:
            base = variation.isFinal ? finale : hitOwn
        case .sunk:
            base = variation.isFinal ? finale : (variation.isMine ? sunk : sunkOwn)
        case .sunkOwn:
            base = variation.isFinal ? finale : sunkOwn
        case .finalBlow:
            base = finale
        case .lastShip:
            base = variation.isMine ? lastShipDown : lastShipUp
        case .shuffle:
            base = shuffle(count: variation.count)
        case .streak:
            base = streak(count: variation.count)
        default:
            base = signature(for: event)
        }
        return variation.intensity == 1 ? base : base.scaled(by: variation.intensity)
    }

    /// The plain signature of every event (§4.2 of the motion spec), before any variation.
    static func signature(for event: FeedbackEvent) -> HapticScore {
        switch event {
        case .select:
            // One light tap as the ghost snaps or a toggle flips.
            return HapticScore(events: [.transient(at: 0, intensity: 0.35, sharpness: 0.6)])
        case .aim:
            // A crisp lock-on tick, then the clack of the brackets landing.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.45, sharpness: 0.9),
                .transient(at: 0.12, intensity: 0.6, sharpness: 0.4),
            ])
        case .place:
            // A plunk: a tap with a little weight under it.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.6, sharpness: 0.3),
                .continuous(from: 0.02, for: 0.08, intensity: 0.3, sharpness: 0.2),
            ])
        case .rotate:
            // Two clicks as the ship turns.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.4, sharpness: 0.7),
                .transient(at: 0.06, intensity: 0.4, sharpness: 0.7),
            ])
        case .shuffle:
            return shuffle(count: 1)
        case .invalid:
            // Two hard, sharp blips: "not there".
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.8, sharpness: 1),
                .transient(at: 0.06, intensity: 0.8, sharpness: 1),
            ])
        case .castOff:
            // Two rigid clicks as the locks close, then the whoosh of departure dying away.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.9, sharpness: 0.5),
                .transient(at: 0.09, intensity: 0.9, sharpness: 0.5),
                .ramp(from: 0.2, for: 0.4, intensity: (0.3, 0), sharpness: (0.3, 0.3)),
            ])
        case .opening:
            // BATTLE STATIONS: the title slams, a short drone, the second thump.
            return HapticScore(events: [
                .transient(at: 0, intensity: 1, sharpness: 0.9),
                .ramp(from: 0, for: 0.25, intensity: (0.6, 0), sharpness: (0.3, 0.3)),
                .transient(at: 0.18, intensity: 0.8, sharpness: 0.6),
            ])
        case .matchFound:
            // A sonar ping and its answer.
            return HapticScore(events: [
                .transient(at: 0, intensity: 0.5, sharpness: 0.7),
                .transient(at: 0.32, intensity: 0.6, sharpness: 0.8),
            ])
        case .fire:
            // The kick, then a rumble that builds for exactly the shell's flight and ends as the landing starts.
            return HapticScore(events: [
                .transient(at: 0, intensity: 1, sharpness: 0.8),
                .ramp(from: 0, for: Timing.shellFlight, intensity: (0.15, 0.55), sharpness: (0.3, 0.7)),
            ])
        case .miss:
            return miss
        case .nearMiss:
            // The splash, with a sharp tick as the column goes up beside the hull.
            return HapticScore(events: miss.events + [.transient(at: 0.05, intensity: 0.4, sharpness: 0.9)])
        case .hit:
            return hit
        case .hitOwn:
            return hitOwn
        case .sunk:
            return sunk
        case .sunkOwn:
            return sunkOwn
        case .finalBlow:
            return finale
        case .stamp:
            // One heavy slam with a short rumble under it.
            return HapticScore(events: [
                .transient(at: 0, intensity: 1, sharpness: 0.3),
                .ramp(from: 0, for: 0.12, intensity: (0.5, 0), sharpness: (0.2, 0.2)),
            ])
        case .incoming:
            // The enemy's guns, far away.
            return HapticScore(events: [.transient(at: 0, intensity: 0.3, sharpness: 0.3)])
        case .whistle:
            // A rumble rising in strength and sharpness for the length of the telegraph; it ends as
            // the landing pattern starts.
            return HapticScore(events: [
                .ramp(from: 0, for: Timing.whistle, intensity: (0.1, 0.5), sharpness: (0.2, 0.6)),
            ])
        case .turnSting:
            // Two light taps on the chime's two notes.
            return HapticScore(events: taps(at: SoundSynthesis.noteStarts[.turnSting] ?? [0, 0.09], intensity: 0.5, sharpness: [0.45, 0.5]))
        case .theirTurn:
            // The faintest nudge as the bezel dims.
            return HapticScore(events: [.transient(at: 0, intensity: 0.3, sharpness: 0.3)])
        case .streak:
            return streak(count: 3)
        case .lastShip:
            return lastShipUp
        case .victory:
            // Four rising taps on the fanfare's notes, then a warm hold on the chord that fades.
            let notes = SoundSynthesis.noteStarts[.victory] ?? [0, 0.13, 0.26, 0.39]
            let last = notes.last ?? 0.39
            return HapticScore(events: [
                .transient(at: notes[0], intensity: 0.7, sharpness: 0.6),
                .transient(at: notes[1], intensity: 0.75, sharpness: 0.6),
                .transient(at: notes[2], intensity: 0.8, sharpness: 0.6),
                .transient(at: last, intensity: 1, sharpness: 0.5),
                .ramp(from: last, for: 0.9, intensity: (0.5, 0), sharpness: (0.3, 0.3)),
            ])
        case .defeat:
            // Falling, softening thuds on the lament's notes.
            let notes = SoundSynthesis.noteStarts[.defeat] ?? [0, 0.28, 0.56, 0.86]
            return HapticScore(events: [
                .transient(at: notes[0], intensity: 0.9, sharpness: 0.2),
                .transient(at: notes[1], intensity: 0.7, sharpness: 0.15),
                .transient(at: notes[2], intensity: 0.55, sharpness: 0.1),
                .transient(at: notes[3], intensity: 0.4, sharpness: 0.05),
            ])
        case .firework:
            // One pop per burst, never more than two a second (the ceremony paces them).
            return HapticScore(events: [.transient(at: 0, intensity: 0.45, sharpness: 0.7)])
        case .thunder:
            // The strike, then a sub rumble rolling away.
            return HapticScore(events: [
                .transient(at: 0, intensity: 1, sharpness: 0.3),
                .ramp(from: 0, for: 0.6, intensity: (0.5, 0), sharpness: (0.1, 0.1)),
            ])
        case .toastSuccess:
            // Two taps, up.
            return HapticScore(events: taps(at: SoundSynthesis.noteStarts[.toastSuccess] ?? [0, 0.1], intensity: 0.5, sharpness: [0.5, 0.6], rising: 0.1))
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
        case .lift:
            // A soft click as the ship comes up.
            return HapticScore(events: [.transient(at: 0, intensity: 0.35, sharpness: 0.5)])
        case .navigate:
            // A selection tick.
            return HapticScore(events: [.transient(at: 0, intensity: 0.3, sharpness: 0.5)])
        case .burning:
            // A loop: sound only.
            return HapticScore(events: [])
        }
    }

    // MARK: Families

    /// A soft thud, then the patter of droplets coming down.
    private static let miss = HapticScore(events: [
        .transient(at: 0, intensity: 0.5, sharpness: 0.15),
        .transient(at: 0.09, intensity: 0.2, sharpness: 0.5),
        .transient(at: 0.16, intensity: 0.2, sharpness: 0.5),
        .transient(at: 0.24, intensity: 0.15, sharpness: 0.5),
    ])

    /// A sharp crack, then a rumble that softens as it dies.
    private static let hit = HapticScore(events: [
        .transient(at: 0, intensity: 1, sharpness: 0.75),
        .ramp(from: 0, for: 0.35, intensity: (0.6, 0), sharpness: (0.5, 0.2)),
    ])

    /// Their shell on your hull: a dull thud and a longer, rounder rumble.
    private static let hitOwn = HapticScore(events: [
        .transient(at: 0, intensity: 1, sharpness: 0.25),
        .ramp(from: 0, for: 0.5, intensity: (0.6, 0), sharpness: (0.2, 0.2)),
    ])

    /// The hit, three escalating secondaries going off down the hull (never faster than the chain
    /// detonation on screen), then a long rumble falling away as she goes.
    private static let sunk = HapticScore(events: [
        .transient(at: 0, intensity: 1, sharpness: 0.75),
        .transient(at: Timing.secondaryStep, intensity: 0.7, sharpness: 0.7),
        .transient(at: Timing.secondaryStep * 2, intensity: 0.85, sharpness: 0.7),
        .transient(at: Timing.secondaryStep * 3, intensity: 1, sharpness: 0.7),
        .ramp(from: Timing.listStart, for: 1.2, intensity: (0.7, 0), sharpness: (0.5, 0.1)),
    ])

    /// Your ship going down: the sinking, then the hull's groan.
    private static let sunkOwn = HapticScore(events: sunk.events + [
        .continuous(from: Timing.listStart + 1.2, for: 0.3, intensity: 0.5, sharpness: 0.05),
    ])

    /// The last landing, in slow motion: one crack, a long rumble, and three fading echoes.
    private static let finale = HapticScore(events: [
        .transient(at: 0, intensity: 1, sharpness: 0.8),
        .ramp(from: 0, for: 1.4, intensity: (0.6, 0), sharpness: (0.3, 0.3)),
        .transient(at: 0.5, intensity: 0.5, sharpness: 0.3),
        .transient(at: 0.9, intensity: 0.4, sharpness: 0.3),
        .transient(at: 1.3, intensity: 0.3, sharpness: 0.3),
    ])

    /// Their last ship: a two-note sting, up.
    private static let lastShipUp = HapticScore(events: [
        .transient(at: 0, intensity: 0.6, sharpness: 0.5),
        .transient(at: 0.18, intensity: 0.8, sharpness: 0.6),
    ])

    /// Your last ship: the sting, down.
    private static let lastShipDown = HapticScore(events: [
        .transient(at: 0, intensity: 0.8, sharpness: 0.6),
        .transient(at: 0.18, intensity: 0.5, sharpness: 0.4),
    ])

    /// One soft tap per ship as the fleet re-forms, `Timing.Stagger.ship` apart.
    private static func shuffle(count: Int) -> HapticScore {
        let taps = min(max(count, 1), Timing.Stagger.maxItems)
        return HapticScore(events: (0..<taps).map { index in
            .transient(at: Double(index) * Timing.Stagger.ship, intensity: 0.35, sharpness: 0.4)
        })
    }

    /// Quick rising ticks on the streak chip: three at the first streak, one more for every two
    /// hits after, never more than five.
    private static func streak(count: Int) -> HapticScore {
        let ticks = min(5, max(3, 3 + (count - 3) / 2))
        return HapticScore(events: (0..<ticks).map { index in
            .transient(at: Double(index) * 0.07, intensity: index < 2 ? 0.6 : 0.7, sharpness: 0.9)
        })
    }

    /// Taps at `times`, with `sharpness` per tap and `rising` added to the intensity of each after the first.
    private static func taps(at times: [TimeInterval], intensity: Double, sharpness: [Double], rising: Double = 0) -> [Event] {
        times.enumerated().map { index, time in
            .transient(
                at: time,
                intensity: min(1, intensity + rising * Double(index)),
                sharpness: sharpness[min(index, sharpness.count - 1)]
            )
        }
    }
}
