import Foundation

/// One particle of a seeded, analytic effect: a spark, a droplet, a puff of smoke. Particles are
/// generated once from a seed and read per frame from the time since their effect began. Nothing
/// steps or mutates, so the same seed draws the same burst on the mini map, the full board, the Fleet
/// sheet and in a filmstrip, and a view recreated mid-burst resumes at the right frame.
///
/// Positions, velocities and sizes are in units: cells on a board, points in a scene. The y axis grows
/// downward, as on screen, so something thrown upward has a negative vertical velocity. Foundation
/// only, so the maths is tested on Linux; `ParticleRenderer` (Views/Board/Particles.swift) draws it.
struct Particle: Sendable, Equatable {
    enum Kind: UInt8, Sendable {
        case spark, ember, droplet, puff, shard, bubble, ring, streak, foam, star
    }

    var origin: SIMD2<Double>
    /// Units per second, at birth.
    var velocity: SIMD2<Double>
    /// Units per second², downward.
    var gravity: Double
    /// Per second; 0 is none. With drag the particle travels at most |velocity| / drag.
    var drag: Double
    /// Seconds into the effect at which the particle is born.
    var delay: TimeInterval
    /// Seconds it lives.
    var life: TimeInterval
    /// Its radius (or a ring's final radius, or a streak's width), in units.
    var size: Double
    /// Radians per second, for anything drawn with a facing.
    var spin: Double
    /// 0…1 along the kind's colour ramp.
    var tint: Double
    var kind: Kind

    /// Seconds since the particle was born, `t` seconds into its effect: nil before its `delay` and
    /// once its `life` is over.
    func age(at t: TimeInterval) -> TimeInterval? {
        // Against `delay + life` rather than `t - delay < life`, so a caller's `delay + life` is the
        // exact moment of death however the floating point falls.
        guard life > 0, t >= delay, t < delay + life else { return nil }
        return t - delay
    }

    /// 0…1 through the particle's life at `t`: 0 before it is born, 1 once it has gone.
    func progress(at t: TimeInterval) -> Double {
        guard t > delay else { return 0 }
        guard life > 0, t < delay + life else { return 1 }
        return min(1, (t - delay) / life)
    }

    /// Where the particle is at `t`: origin + v·τ + ½g·τ², with τ = (1 − e^(−drag·age)) / drag (the
    /// age itself without drag), so drag eases it to a stop and gravity pulls it down the whole way.
    /// Before its birth it waits at its origin; after its death it stays where it died.
    func position(at t: TimeInterval) -> SIMD2<Double> {
        let age = min(max(0, t - delay), max(0, life))
        let tau: Double
        if drag > 0 {
            tau = (1 - exp(-drag * age)) / drag
        } else {
            tau = age
        }
        return origin + velocity * tau + SIMD2(0, 0.5 * gravity * tau * tau)
    }

    /// 0…1: how visible the particle is at `t`, and 0 whenever it isn't alive.
    func alpha(at t: TimeInterval) -> Double {
        guard age(at: t) != nil else { return 0 }
        let p = progress(at: t)
        switch kind {
        case .ring, .foam:
            return 1 - p
        case .puff:
            return min(1, p / 0.08) * (1 - p)
        case .spark, .ember, .droplet, .shard, .bubble, .streak, .star:
            return min(1, (1 - p) / 0.45)
        }
    }

    /// A multiplier on `size` at `t`: rings and puffs grow, sparks and droplets shrink.
    func scale(at t: TimeInterval) -> Double {
        let p = progress(at: t)
        switch kind {
        case .ring, .foam:
            return 0.15 + 0.85 * Particle.easeOut(p)
        case .puff:
            return 1 + 1.4 * p
        case .spark:
            return 1 - 0.6 * p
        case .ember:
            return 1 - 0.5 * p
        case .droplet:
            return 1 - 0.4 * p
        case .shard, .streak:
            return 1
        case .bubble:
            return 0.6 + 0.5 * p
        case .star:
            return 1 - 0.6 * p * p
        }
    }

    static func easeOut(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return 1 - (1 - clamped) * (1 - clamped) * (1 - clamped)
    }
}

/// A small, repeatable generator (SplitMix64) so a burst is the same for a seed on every board and
/// in every filmstrip. Use it wherever an effect needs randomness that must replay.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The effects' particle lists, each a pure function of a seed. Positions are relative to the point
/// the renderer is given (the landing cell's centre, a ship's centre, a firework's scene origin).
enum Emitters {
    enum BurstShape: Sendable {
        case peony, chrysanthemum, willow
    }

    /// Cells a second² on a board: a droplet thrown up at 3 cells a second is back on the water in 0.6 s.
    static let gravity: Double = 10
    /// How long one loop of a burning cell's smoke lasts. `smoke(cell:phase:isTargetBoard:)` returns two
    /// loops' worth of puffs, so draw it at `smokePeriod + time.truncatingRemainder(dividingBy: smokePeriod)`.
    static let smokePeriod: TimeInterval = 2.4

    /// A shell in open water: 14 droplets thrown up in a cone that fall back under gravity, 6 rings
    /// where the first of them land (0.4–0.8 s), and 3 foam rings from the column. `close` is the
    /// near-miss variant: a tighter, quieter splash.
    static func splash(seed: UInt64, close: Bool = false) -> [Particle] {
        var generator = SplitMix64(seed: seed)
        var particles: [Particle] = []
        particles.reserveCapacity(23)
        let reach = close ? 0.6 : 1.0
        var landings: [(x: Double, at: TimeInterval)] = []
        for _ in 0..<14 {
            let angle = Double.random(in: -0.45...0.45, using: &generator)
            let speed = Double.random(in: 2.4...4.4, using: &generator) * reach
            let velocity = SIMD2(sin(angle) * speed, -cos(angle) * speed)
            let flight = 2 * -velocity.y / gravity
            let delay = Double.random(in: 0...0.06, using: &generator)
            particles.append(Particle(
                origin: .zero,
                velocity: velocity,
                gravity: gravity,
                drag: 0,
                delay: delay,
                life: flight,
                size: Double.random(in: 0.045...0.09, using: &generator) * (close ? 0.8 : 1),
                spin: 0,
                tint: Double.random(in: 0...1, using: &generator),
                kind: .droplet
            ))
            landings.append((x: velocity.x * flight, at: delay + flight))
        }
        for landing in landings.sorted(by: { $0.at < $1.at }).prefix(6) {
            particles.append(Particle(
                origin: SIMD2(landing.x, 0),
                velocity: .zero,
                gravity: 0,
                drag: 0,
                delay: landing.at,
                life: 0.5,
                size: Double.random(in: 0.22...0.36, using: &generator) * reach,
                spin: 0,
                tint: 0,
                kind: .ring
            ))
        }
        for index in 0..<3 {
            particles.append(Particle(
                origin: .zero,
                velocity: .zero,
                gravity: 0,
                drag: 0,
                delay: Double(index) * 0.13,
                life: 0.9,
                size: (1.1 - Double(index) * 0.12) * reach,
                spin: 0,
                tint: close ? 1 : 0,
                kind: .foam
            ))
        }
        return particles
    }

    /// A shell against a hull: 24 sparks under gravity, 5 tumbling shards and, for the primary blast,
    /// 8 embers drifting up for 1.6 s and 5 puffs of smoke. `scale` shrinks a secondary blast (0.55
    /// along a sinking hull); `isPrimary: false` leaves out the embers and smoke, so a chain of them
    /// doesn't bury the ship.
    static func detonation(seed: UInt64, scale: Double = 1, isPrimary: Bool = true) -> [Particle] {
        var generator = SplitMix64(seed: seed)
        var particles: [Particle] = []
        particles.reserveCapacity(isPrimary ? 42 : 29)
        for _ in 0..<24 {
            let angle = Double.random(in: 0..<(2 * Double.pi), using: &generator)
            let speed = Double.random(in: 3...7, using: &generator) * scale
            particles.append(Particle(
                origin: .zero,
                velocity: direction(angle) * speed,
                gravity: 6,
                drag: 3.5,
                delay: Double.random(in: 0...0.03, using: &generator),
                life: Double.random(in: 0.45...0.85, using: &generator),
                size: Double.random(in: 0.035...0.07, using: &generator) * scale,
                spin: 0,
                tint: Double.random(in: 0...1, using: &generator),
                kind: .spark
            ))
        }
        for _ in 0..<5 {
            let angle = Double.random(in: 0..<(2 * Double.pi), using: &generator)
            let speed = Double.random(in: 1.6...3.2, using: &generator) * scale
            let spin = Double.random(in: 6...14, using: &generator)
            let clockwise = Double.random(in: 0...1, using: &generator) < 0.5
            particles.append(Particle(
                origin: .zero,
                velocity: direction(angle) * speed + SIMD2(0, -1.2 * scale),
                gravity: 7,
                drag: 1.8,
                delay: 0,
                life: Double.random(in: 0.7...1.0, using: &generator),
                size: Double.random(in: 0.07...0.13, using: &generator) * scale,
                spin: clockwise ? spin : -spin,
                tint: Double.random(in: 0...1, using: &generator),
                kind: .shard
            ))
        }
        guard isPrimary else { return particles }
        for _ in 0..<8 {
            particles.append(Particle(
                origin: .zero,
                velocity: SIMD2(
                    Double.random(in: -0.5...0.5, using: &generator) * scale,
                    -Double.random(in: 0.5...1.1, using: &generator) * scale
                ),
                gravity: 0,
                drag: 1.3,
                delay: Double.random(in: 0.05...0.35, using: &generator),
                life: Double.random(in: 1.2...1.6, using: &generator),
                size: Double.random(in: 0.03...0.055, using: &generator) * scale,
                spin: 0,
                tint: Double.random(in: 0...1, using: &generator),
                kind: .ember
            ))
        }
        for _ in 0..<5 {
            let angle = Double.random(in: 0..<(2 * Double.pi), using: &generator)
            let speed = Double.random(in: 0.3...0.7, using: &generator) * scale
            particles.append(Particle(
                origin: .zero,
                velocity: direction(angle) * speed + SIMD2(0, -0.35 * scale),
                gravity: 0,
                drag: 1.6,
                delay: Double.random(in: 0.1...0.3, using: &generator),
                life: Double.random(in: 0.9...1.3, using: &generator),
                size: Double.random(in: 0.28...0.42, using: &generator) * scale,
                spin: 0,
                tint: Double.random(in: 0...1, using: &generator),
                kind: .puff
            ))
        }
        return particles
    }

    /// Smoke from a burning cell: 6 puffs rising in a loop of `smokePeriod` seconds, returned twice
    /// (the second loop delayed by one period) so that drawing them at `smokePeriod + time mod smokePeriod`
    /// is seamless. `phase` offsets the loop so neighbouring cells don't puff together. On the target
    /// board the puffs stay small and close, to be clipped to their cell; on the home board they rise
    /// in a short column.
    static func smoke(cell: Int, phase: Double, isTargetBoard: Bool) -> [Particle] {
        var generator = SplitMix64(seed: 0x5A17 &+ UInt64(truncatingIfNeeded: cell) &* 0x9E37_79B9_7F4A_7C15)
        let period = smokePeriod
        let rise: ClosedRange<Double> = isTargetBoard ? 0.22...0.36 : 0.45...0.8
        let sway = isTargetBoard ? 0.08 : 0.2
        let size: ClosedRange<Double> = isTargetBoard ? 0.1...0.16 : 0.14...0.24
        var base: [Particle] = []
        base.reserveCapacity(6)
        for index in 0..<6 {
            let offset = (Double(index) / 6 * period + phase).truncatingRemainder(dividingBy: period)
            base.append(Particle(
                origin: SIMD2(Double.random(in: -0.12...0.12, using: &generator), 0),
                velocity: SIMD2(Double.random(in: -sway...sway, using: &generator), -Double.random(in: rise, using: &generator)),
                gravity: 0,
                drag: isTargetBoard ? 1.6 : 0.9,
                delay: offset < 0 ? offset + period : offset,
                life: period,
                size: Double.random(in: size, using: &generator),
                spin: 0,
                tint: Double.random(in: 0...1, using: &generator),
                kind: .puff
            ))
        }
        var looped = base
        for puff in base {
            var again = puff
            again.delay += period
            looped.append(again)
        }
        return looped
    }

    /// Water boiling around a sinking hull: 18 bubbles rising from the rect (x, y, width, height,
    /// relative to the renderer's point) over the sinking, and 3 dark slick rings spreading from its
    /// centre.
    static func boil(rect: SIMD4<Double>, seed: UInt64) -> [Particle] {
        var generator = SplitMix64(seed: seed)
        var particles: [Particle] = []
        particles.reserveCapacity(21)
        let width = rect.z
        let height = rect.w
        for _ in 0..<18 {
            let origin = SIMD2(
                rect.x + Double.random(in: 0.1...0.9, using: &generator) * width,
                rect.y + Double.random(in: 0.15...0.85, using: &generator) * height
            )
            particles.append(Particle(
                origin: origin,
                velocity: SIMD2(Double.random(in: -0.08...0.08, using: &generator), -Double.random(in: 0.12...0.3, using: &generator)),
                gravity: 0,
                drag: 0,
                delay: Double.random(in: 0.25...2.3, using: &generator),
                life: Double.random(in: 0.5...1.0, using: &generator),
                size: Double.random(in: 0.025...0.06, using: &generator),
                spin: 0,
                tint: Double.random(in: 0...1, using: &generator),
                kind: .bubble
            ))
        }
        let centre = SIMD2(rect.x + width / 2, rect.y + height / 2)
        let span = max(width, height)
        for index in 0..<3 {
            particles.append(Particle(
                origin: centre,
                velocity: .zero,
                gravity: 0,
                drag: 0,
                delay: 0.35 + Double(index) * 0.5,
                life: 2.2,
                size: span * (0.5 + 0.25 * Double(index)),
                spin: 0,
                tint: 1,
                kind: .ring
            ))
        }
        return particles
    }

    /// A ship dropped into its berth: 8 droplets thrown up from the rect (x, y, width, height,
    /// relative to the renderer's point) and 3 rings from its centre.
    static func plunk(rect: SIMD4<Double>, seed: UInt64) -> [Particle] {
        var generator = SplitMix64(seed: seed)
        var particles: [Particle] = []
        particles.reserveCapacity(11)
        let width = rect.z
        let height = rect.w
        for _ in 0..<8 {
            let origin = SIMD2(
                rect.x + Double.random(in: 0...1, using: &generator) * width,
                rect.y + Double.random(in: 0...1, using: &generator) * height
            )
            let angle = Double.random(in: -0.5...0.5, using: &generator)
            let speed = Double.random(in: 1.2...2.4, using: &generator)
            let velocity = SIMD2(sin(angle) * speed, -cos(angle) * speed)
            particles.append(Particle(
                origin: origin,
                velocity: velocity,
                gravity: gravity,
                drag: 0,
                delay: Double.random(in: 0...0.05, using: &generator),
                life: 2 * -velocity.y / gravity,
                size: Double.random(in: 0.04...0.08, using: &generator),
                spin: 0,
                tint: Double.random(in: 0...1, using: &generator),
                kind: .droplet
            ))
        }
        let centre = SIMD2(rect.x + width / 2, rect.y + height / 2)
        let span = max(width, height)
        for index in 0..<3 {
            particles.append(Particle(
                origin: centre,
                velocity: .zero,
                gravity: 0,
                drag: 0,
                delay: Double(index) * 0.1,
                life: 0.7,
                size: span * (0.45 + 0.2 * Double(index)),
                spin: 0,
                tint: 0,
                kind: .ring
            ))
        }
        return particles
    }

    /// Foam behind a ship under way: 12 streaks trailing from `from` against `heading`, spreading a
    /// little to either side as they fade.
    static func wake(from: SIMD2<Double>, heading: SIMD2<Double>, seed: UInt64) -> [Particle] {
        var generator = SplitMix64(seed: seed)
        let length = (heading.x * heading.x + heading.y * heading.y).squareRoot()
        let forward = length > 0 ? heading / length : SIMD2(1, 0)
        let side = SIMD2(-forward.y, forward.x)
        var particles: [Particle] = []
        particles.reserveCapacity(12)
        for index in 0..<12 {
            let back = Double(index) / 12 * 1.6 + Double.random(in: 0...0.1, using: &generator)
            let lateral = Double.random(in: -0.18...0.18, using: &generator)
            particles.append(Particle(
                origin: from - forward * back + side * lateral,
                velocity: -forward * Double.random(in: 0.2...0.4, using: &generator) + side * (lateral * 1.5),
                gravity: 0,
                drag: 0.8,
                delay: Double(index) * 0.04,
                life: Double.random(in: 0.6...1.1, using: &generator),
                size: Double.random(in: 0.06...0.14, using: &generator),
                spin: 0,
                tint: 0,
                kind: .foam
            ))
        }
        return particles
    }

    /// A rocket from `launch` to `apex` in 0.9 s (one streak), bursting there into `count` stars of
    /// one hue: a peony (a round shell), a chrysanthemum (uneven speeds, so the stars spread into a
    /// ragged bloom) or a willow (heavy, long-lived stars that droop). In points, for a scene.
    static func firework(seed: UInt64, launch: SIMD2<Double>, apex: SIMD2<Double>, shape: BurstShape, count: Int) -> [Particle] {
        var generator = SplitMix64(seed: seed)
        let rise: TimeInterval = 0.9
        let stars = max(0, count)
        var particles: [Particle] = []
        particles.reserveCapacity(stars + 1)
        let hue = Double.random(in: 0...1, using: &generator)
        particles.append(Particle(
            origin: launch,
            velocity: (apex - launch) / rise,
            gravity: 0,
            drag: 0,
            delay: 0,
            life: rise,
            size: 1.6,
            spin: 0,
            tint: hue,
            kind: .streak
        ))
        let speeds: ClosedRange<Double>
        let drag: Double
        let pull: Double
        let lives: ClosedRange<Double>
        switch shape {
        case .peony:
            speeds = 140...180
            drag = 2.4
            pull = 40
            lives = 1.1...1.5
        case .chrysanthemum:
            speeds = 50...230
            drag = 2.0
            pull = 40
            lives = 1.0...1.8
        case .willow:
            speeds = 90...150
            drag = 1.1
            pull = 110
            lives = 1.9...2.5
        }
        for _ in 0..<stars {
            let angle = Double.random(in: 0..<(2 * Double.pi), using: &generator)
            let speed = Double.random(in: speeds, using: &generator)
            let shade = hue + Double.random(in: -0.05...0.05, using: &generator)
            particles.append(Particle(
                origin: apex,
                velocity: direction(angle) * speed,
                gravity: pull,
                drag: drag,
                delay: rise,
                life: Double.random(in: lives, using: &generator),
                size: Double.random(in: 1.8...3.2, using: &generator),
                spin: 0,
                tint: min(1, max(0, shade)),
                kind: .star
            ))
        }
        return particles
    }

    /// A hull breaking the surface: 4 rings spreading from `center` `Timing.Stagger.surfacing` apart,
    /// and 6 droplets thrown up around it.
    static func surfaceRings(center: SIMD2<Double>, seed: UInt64) -> [Particle] {
        var generator = SplitMix64(seed: seed)
        var particles: [Particle] = []
        particles.reserveCapacity(10)
        for index in 0..<4 {
            particles.append(Particle(
                origin: center,
                velocity: .zero,
                gravity: 0,
                drag: 0,
                delay: Double(index) * Timing.Stagger.surfacing,
                life: 1.1,
                size: 0.55 + 0.35 * Double(index),
                spin: 0,
                tint: 0,
                kind: .ring
            ))
        }
        for _ in 0..<6 {
            let angle = Double.random(in: 0..<(2 * Double.pi), using: &generator)
            let distance = Double.random(in: 0.1...0.4, using: &generator)
            particles.append(Particle(
                origin: center + direction(angle) * distance,
                velocity: SIMD2(0, -Double.random(in: 0.6...1.2, using: &generator)),
                gravity: gravity,
                drag: 0,
                delay: Double.random(in: 0.05...0.3, using: &generator),
                life: Double.random(in: 0.2...0.3, using: &generator),
                size: Double.random(in: 0.03...0.06, using: &generator),
                spin: 0,
                tint: 0,
                kind: .droplet
            ))
        }
        return particles
    }

    /// The unit vector `angle` radians round from the x axis (clockwise on screen).
    static func direction(_ angle: Double) -> SIMD2<Double> {
        SIMD2(cos(angle), sin(angle))
    }
}
