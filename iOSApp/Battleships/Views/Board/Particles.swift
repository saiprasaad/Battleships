import SwiftUI

/// A burst of particles, generated once from a seed and read per frame from the time since the burst,
/// so nothing mutates inside a timeline and the same seed draws the same burst wherever it is shown:
/// the mini map, the full board, a filmstrip. Distances are in cells, so one field fits any board.
struct ParticleField: Sendable {
    struct Particle: Sendable {
        /// Direction of travel, in radians.
        let angle: CGFloat
        /// At the moment of the burst, in cells per second.
        let speed: CGFloat
        /// Radius, as a fraction of a cell.
        let size: CGFloat
        /// Seconds until it has faded out.
        let life: TimeInterval
        /// Picks a colour from the caller's palette, 0…1.
        let tint: CGFloat
        /// Radians per second, for anything drawn with a facing.
        let spin: CGFloat
        /// Downward pull, in cells per second².
        let gravity: CGFloat
    }

    let particles: [Particle]

    /// `count` particles thrown from one point, every direction in `spread` (radians) equally likely.
    /// The same `seed` always gives the same burst; it never touches the system's generator, so it
    /// can be called from a `@State` default value.
    nonisolated static func burst(
        count: Int,
        seed: UInt64,
        speed: ClosedRange<CGFloat>,
        size: ClosedRange<CGFloat>,
        life: ClosedRange<TimeInterval>,
        gravity: CGFloat = 0,
        spread: ClosedRange<CGFloat> = 0...(2 * .pi)
    ) -> ParticleField {
        var generator = SplitMix64(seed: seed)
        var particles: [Particle] = []
        particles.reserveCapacity(max(0, count))
        for _ in 0..<max(0, count) {
            particles.append(Particle(
                angle: CGFloat.random(in: spread, using: &generator),
                speed: CGFloat.random(in: speed, using: &generator),
                size: CGFloat.random(in: size, using: &generator),
                life: TimeInterval.random(in: life, using: &generator),
                tint: CGFloat.random(in: 0...1, using: &generator),
                spin: CGFloat.random(in: -4...4, using: &generator),
                gravity: gravity
            ))
        }
        return ParticleField(particles: particles)
    }

    /// Where a particle is `time` seconds after the burst, in points, for a cell of `cell` points.
    /// It leaves at its speed and eases out as drag takes hold, coming to rest at the end of its life
    /// a third of `speed × life` cells out; gravity pulls it down the whole way.
    func position(of index: Int, at time: TimeInterval, origin: CGPoint, cell: CGFloat) -> CGPoint {
        let particle = particles[index]
        let life = CGFloat(particle.life)
        let t = min(CGFloat(max(0, time)), life)
        let progress = life > 0 ? t / life : 1
        let remaining = 1 - progress
        let eased = 1 - remaining * remaining * remaining
        let distance = particle.speed * life / 3 * eased * cell
        let drop = 0.5 * particle.gravity * t * t * cell
        return CGPoint(
            x: origin.x + cos(particle.angle) * distance,
            y: origin.y + sin(particle.angle) * distance + drop
        )
    }

    /// 1 → 0 over the particle's life; 0 once it has gone.
    func alpha(of index: Int, at time: TimeInterval) -> CGFloat {
        let particle = particles[index]
        guard time < particle.life, particle.life > 0 else { return 0 }
        guard time > 0 else { return 1 }
        return CGFloat(1 - time / particle.life)
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

extension GraphicsContext {
    /// Draws every live particle as a dot or, with a `trail`, as a streak from where it was `trail`
    /// seconds earlier to where it is now. `color` picks each particle's colour (from its `tint`,
    /// say); its alpha fades it out over its life. Blend mode and clipping are the caller's: set them
    /// on the context (or a copy of it) first.
    mutating func drawParticles(
        _ field: ParticleField,
        at time: TimeInterval,
        origin: CGPoint,
        cell: CGFloat,
        color: (ParticleField.Particle) -> Color,
        trail: TimeInterval = 0
    ) {
        for index in field.particles.indices {
            let alpha = field.alpha(of: index, at: time)
            guard alpha > 0 else { continue }
            let particle = field.particles[index]
            let head = field.position(of: index, at: time, origin: origin, cell: cell)
            let radius = max(0.5, cell * particle.size)
            let paint = color(particle).opacity(Double(alpha))
            if trail > 0 {
                let tail = field.position(of: index, at: time - trail, origin: origin, cell: cell)
                var streak = Path()
                streak.move(to: tail)
                streak.addLine(to: head)
                stroke(streak, with: .color(paint), style: StrokeStyle(lineWidth: radius * 2, lineCap: .round))
            }
            fill(
                Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(paint)
            )
        }
    }
}
