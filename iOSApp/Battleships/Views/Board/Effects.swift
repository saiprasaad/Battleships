import SwiftUI

/// A shell landing in a cell: it whistles in, then either explodes against a hull (sparks, a
/// fireball, a shock wave and smoke) or throws up a splash and ripples.
struct ImpactView: View {
    let isHit: Bool
    let cell: CGFloat
    @State private var start = Date()
    @State private var particles = ImpactBurst.makeParticles()

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                ImpactBurst.draw(isHit: isHit, elapsed: elapsed, particles: particles, cell: cell, in: context, size: size)
            }
        }
        .frame(width: cell * 3.4, height: cell * 3.4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum ImpactBurst {
    struct Particle: Sendable {
        /// Direction of travel, in radians.
        let angle: CGFloat
        /// How far it flies, in cells.
        let reach: CGFloat
        /// Radius, as a fraction of a cell.
        let size: CGFloat
        /// Picks a colour from the particle's palette.
        let tint: CGFloat
    }

    /// Seconds until the shell lands.
    static let flightTime: CGFloat = 0.16
    /// Seconds from firing until the effect has faded.
    static let duration: CGFloat = 1.15

    static func makeParticles() -> [Particle] {
        (0..<18).map { _ in
            Particle(
                angle: .random(in: 0..<(2 * .pi)),
                reach: .random(in: 0.55...1.4),
                size: .random(in: 0.05...0.12),
                tint: .random(in: 0...1)
            )
        }
    }

    @MainActor
    static func draw(isHit: Bool, elapsed: TimeInterval, particles: [Particle], cell: CGFloat, in context: GraphicsContext, size: CGSize) {
        let time = CGFloat(elapsed)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        if time < flightTime {
            // Incoming: a ring closing on the target.
            let progress = time / flightTime
            context.stroke(
                Path(ellipseIn: circle(center, cell * (1.1 - 0.95 * progress))),
                with: .color(.white.opacity(0.2 + 0.6 * progress)),
                lineWidth: 1.5
            )
            context.fill(Path(ellipseIn: circle(center, cell * 0.09)), with: .color(.white.opacity(progress)))
            return
        }
        let progress = min(1, (time - flightTime) / (duration - flightTime))
        guard progress < 1 else { return }
        if isHit {
            drawExplosion(progress, center: center, particles: particles, cell: cell, in: context)
        } else {
            drawSplash(progress, center: center, particles: particles, cell: cell, in: context)
        }
    }

    @MainActor
    private static func drawExplosion(_ t: CGFloat, center: CGPoint, particles: [Particle], cell: CGFloat, in context: GraphicsContext) {
        let fade = 1 - t
        let burst = easeOut(t)

        // Smoke drifting from the blast, drawn first so the fire glows over it.
        for (index, particle) in particles.prefix(5).enumerated() {
            let age = t - 0.15 - CGFloat(index) * 0.03
            guard age > 0 else { continue }
            let drift = cell * 0.5 * easeOut(age)
            let puff = CGPoint(x: center.x + cos(particle.angle) * drift, y: center.y + sin(particle.angle) * drift - cell * 0.2 * age)
            let radius = cell * (0.25 + 0.45 * age)
            context.fill(
                Path(ellipseIn: circle(puff, radius)),
                with: .radialGradient(
                    Gradient(colors: [Color.black.opacity(0.4 * (1 - age)), Color.black.opacity(0)]),
                    center: puff,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }

        var light = context
        light.blendMode = .plusLighter

        // The flash.
        if t < 0.25 {
            let flash = 1 - t / 0.25
            let radius = cell * (0.6 + 1.2 * t)
            light.fill(
                Path(ellipseIn: circle(center, radius)),
                with: .radialGradient(
                    Gradient(colors: [Color.white.opacity(flash), Theme.ember.opacity(0.7 * flash), Theme.flame.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }

        // The fireball.
        let fireball = cell * (0.35 + 0.75 * burst)
        light.fill(
            Path(ellipseIn: circle(center, fireball)),
            with: .radialGradient(
                Gradient(colors: [
                    Theme.ember.opacity(fade),
                    Theme.flame.opacity(0.85 * fade),
                    Theme.hit.opacity(0.5 * fade),
                    Theme.hit.opacity(0),
                ]),
                center: center,
                startRadius: 0,
                endRadius: fireball
            )
        )

        // The shock wave.
        context.stroke(
            Path(ellipseIn: circle(center, cell * (0.4 + 1.25 * burst))),
            with: .color(Theme.flame.opacity(0.75 * fade)),
            lineWidth: 0.5 + cell * 0.07 * fade
        )

        // Sparks, each trailing a streak.
        let trail = easeOut(max(0, t - 0.06))
        for particle in particles {
            let reach = cell * particle.reach * 1.3
            let dx = cos(particle.angle)
            let dy = sin(particle.angle)
            let head = CGPoint(x: center.x + dx * reach * burst, y: center.y + dy * reach * burst)
            let tail = CGPoint(x: center.x + dx * reach * trail, y: center.y + dy * reach * trail)
            let color = particle.tint > 0.5 ? Theme.ember : Theme.flame
            var streak = Path()
            streak.move(to: tail)
            streak.addLine(to: head)
            light.stroke(streak, with: .color(color.opacity(0.8 * fade)), lineWidth: max(0.5, cell * particle.size * 0.6 * fade))
            light.fill(Path(ellipseIn: circle(head, cell * particle.size * fade)), with: .color(color.opacity(fade)))
        }
    }

    @MainActor
    private static func drawSplash(_ t: CGFloat, center: CGPoint, particles: [Particle], cell: CGFloat, in context: GraphicsContext) {
        // Ripples spreading out, one after another.
        for ring in 0..<3 {
            let delay = CGFloat(ring) * 0.13
            let local = (t - delay) / (1 - delay)
            guard local > 0, local < 1 else { continue }
            context.stroke(
                Path(ellipseIn: circle(center, cell * (0.15 + 1.05 * easeOut(local)))),
                with: .color(.white.opacity(0.75 * (1 - local))),
                lineWidth: 0.5 + 1.5 * (1 - local)
            )
        }

        // The column of water collapsing.
        if t < 0.35 {
            let collapse = 1 - t / 0.35
            let radius = cell * 0.42 * collapse + 1
            context.fill(
                Path(ellipseIn: circle(center, radius)),
                with: .radialGradient(
                    Gradient(colors: [Color.white.opacity(0.95 * collapse), Theme.reticle.opacity(0.4 * collapse), Theme.reticle.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }

        // Droplets thrown clear.
        let fade = 1 - t
        let spread = easeOut(t)
        for particle in particles.prefix(12) {
            let distance = cell * particle.reach * 0.9 * spread
            let drop = CGPoint(x: center.x + cos(particle.angle) * distance, y: center.y + sin(particle.angle) * distance)
            let color = particle.tint > 0.6 ? Theme.reticle : Color.white
            context.fill(Path(ellipseIn: circle(drop, cell * particle.size * 0.8 * fade)), with: .color(color.opacity(0.9 * fade)))
        }
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    private static func easeOut(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return 1 - (1 - clamped) * (1 - clamped) * (1 - clamped)
    }
}

/// Jolts the view sideways each time `trigger` changes, like a hull taking a hit.
struct ShakeEffect: ViewModifier {
    let trigger: Int
    var amplitude: CGFloat = 7
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onChange(of: trigger) {
                guard !reduceMotion else { return }
                Task {
                    let steps: [CGFloat] = [1, -0.8, 0.6, -0.4, 0.2, 0]
                    for step in steps {
                        withAnimation(.easeInOut(duration: 0.045)) {
                            offset = amplitude * step
                        }
                        try? await Task.sleep(for: .milliseconds(45))
                    }
                }
            }
    }
}

extension View {
    func shakes(on trigger: Int, amplitude: CGFloat = 7) -> some View {
        modifier(ShakeEffect(trigger: trigger, amplitude: amplitude))
    }
}

/// A red pulse around the edges of the screen when the player's fleet is hit.
struct DamageFlash: View {
    let trigger: Int
    @State private var intensity = 0.0

    var body: some View {
        GeometryReader { proxy in
            let radius = max(proxy.size.width, proxy.size.height)
            RadialGradient(
                colors: [Theme.hit.opacity(0), Theme.hit.opacity(0.15), Theme.hit.opacity(0.6)],
                center: .center,
                startRadius: radius * 0.25,
                endRadius: radius * 0.75
            )
        }
        .ignoresSafeArea()
        .opacity(intensity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) {
            withAnimation(.easeIn(duration: 0.08)) {
                intensity = 1
            }
            Task {
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(.easeOut(duration: 0.8)) {
                    intensity = 0
                }
            }
        }
    }
}
