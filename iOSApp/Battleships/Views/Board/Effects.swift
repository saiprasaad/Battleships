import SwiftUI

/// A shell landing in a cell, as the boards' `EffectsLayer` draws it: the ring closing on the cell
/// through the last `closingRing` seconds of the shell's flight (timed from the `ShellFlight`), then
/// from the landing (`Impact.start`) either a detonation against a hull (a white-hot core, a fireball,
/// sparks, shards, embers and smoke) or a splash (a flash dot, a column of water, droplets and foam
/// rings). A façade over `Emitters` and `ParticleRenderer`: an effect's particle list is built once
/// (`particles(kind:seed:)`, which the layer caches per effect id) and read per frame.
enum ImpactBurst {
    enum Kind: Hashable, Sendable {
        /// Open water.
        case splash
        /// Open water next to an earlier hit: a tighter, quieter splash.
        case closeSplash
        /// A hull.
        case detonation
        /// One of the chain of blasts along a sinking hull: scale 0.55, never a white core.
        case secondary
    }

    /// Seconds before the landing during which the closing ring plays.
    static let closingRing: TimeInterval = 0.16
    /// Seconds from the landing until the burst itself has faded.
    static let duration: TimeInterval = Timing.impact
    /// Seconds from the landing until the last particle (an ember) has gone.
    static let particleTail: TimeInterval = 1.7

    /// The seed an effect's particles are built from, so the mini map, the board and the Fleet sheet
    /// draw the identical burst for one impact.
    static func seed(for id: UUID) -> UInt64 {
        UInt64(truncatingIfNeeded: id.hashValue)
    }

    /// A seed for the `step`th part of an effect (a blast along a sinking hull).
    static func seed(for id: UUID, step: Int) -> UInt64 {
        seed(for: id) &+ UInt64(truncatingIfNeeded: step) &* 0x9E37_79B9_7F4A_7C15
    }

    static func particles(kind: Kind, seed: UInt64) -> [Particle] {
        switch kind {
        case .splash:
            Emitters.splash(seed: seed)
        case .closeSplash:
            Emitters.splash(seed: seed, close: true)
        case .detonation:
            Emitters.detonation(seed: seed)
        case .secondary:
            Emitters.detonation(seed: seed, scale: 0.55, isPrimary: false)
        }
    }

    /// The ring closing on the cell as the shell comes down: `progress` runs 0…1 over the last
    /// `closingRing` seconds of the flight.
    static func drawClosingRing(progress: Double, cell: CGFloat, at center: CGPoint, in context: inout GraphicsContext) {
        let p = CGFloat(min(1, max(0, progress)))
        context.stroke(
            circle(center, cell * (1.1 - 0.95 * p)),
            with: .color(Color.white.opacity(0.2 + 0.6 * Double(p))),
            lineWidth: 1.5
        )
        context.fill(circle(center, cell * 0.09), with: .color(Color.white.opacity(Double(p))))
    }

    /// Draws the burst `elapsed` seconds after the landing, building its particles from `seed`. The
    /// layer prefers the overload that takes a cached list.
    static func draw(
        kind: Kind,
        elapsed: TimeInterval,
        seed: UInt64,
        cell: CGFloat,
        flashes: Bool,
        at center: CGPoint = .zero,
        budget: Int = MotionPolicy.full.particleBudget,
        in context: inout GraphicsContext
    ) {
        draw(kind: kind, elapsed: elapsed, particles: particles(kind: kind, seed: seed), cell: cell, flashes: flashes, at: center, budget: budget, in: &context)
    }

    /// Draws the burst `elapsed` seconds after the landing from a particle list built by
    /// `particles(kind:seed:)`. `flashes` is off under Dim Flashing Lights and below the full tier,
    /// which leaves out the white core and the flash dot; `budget` is the policy's particle budget.
    static func draw(
        kind: Kind,
        elapsed: TimeInterval,
        particles: [Particle],
        cell: CGFloat,
        flashes: Bool,
        at center: CGPoint,
        budget: Int,
        in context: inout GraphicsContext
    ) {
        guard elapsed >= 0, cell > 0 else { return }
        let t = min(1, elapsed / duration)
        switch kind {
        case .detonation:
            drawExplosion(t, elapsed: elapsed, center: center, cell: cell, flashes: flashes, scale: 1, hasCore: true, in: &context)
        case .secondary:
            drawExplosion(t, elapsed: elapsed, center: center, cell: cell, flashes: flashes, scale: 0.55, hasCore: false, in: &context)
        case .splash, .closeSplash:
            drawSplash(t, elapsed: elapsed, center: center, cell: cell, flashes: flashes, isClose: kind == .closeSplash, in: &context)
        }
        if elapsed < particleTail {
            ParticleRenderer.draw(particles, elapsed: elapsed, unit: cell, at: center, flashes: flashes, budget: budget, in: &context)
        }
    }

    private static func drawExplosion(
        _ t: Double,
        elapsed: TimeInterval,
        center: CGPoint,
        cell: CGFloat,
        flashes: Bool,
        scale: CGFloat,
        hasCore: Bool,
        in context: inout GraphicsContext
    ) {
        guard t < 1 else { return }
        let fade = 1 - t
        let burst = CGFloat(easeOut(t))

        // The fireball, coloured whatever lies beneath it.
        let fireball = cell * (0.35 + 0.85 * burst) * scale
        let dark = Color(red: 0.6, green: 0.08, blue: 0.04)
        context.fill(
            circle(center, fireball),
            with: .radialGradient(
                Gradient(colors: [
                    Theme.ember.opacity(0.95 * fade),
                    Theme.flame.opacity(0.9 * fade),
                    Theme.hit.opacity(0.75 * fade),
                    dark.opacity(0.35 * fade),
                    dark.opacity(0),
                ]),
                center: center,
                startRadius: 0,
                endRadius: fireball
            )
        )

        // A white-hot core, added as light, for the first 220 ms: the primary blast only, with flashes.
        if hasCore, flashes, elapsed < 0.22 {
            let flash = 1 - elapsed / 0.22
            let radius = cell * (0.45 + 2.5 * CGFloat(elapsed))
            context.drawLayer { light in
                light.blendMode = .plusLighter
                light.fill(
                    circle(center, radius),
                    with: .radialGradient(
                        Gradient(colors: [Color.white.opacity(0.9 * flash), Theme.ember.opacity(0.5 * flash), Theme.flame.opacity(0)]),
                        center: center,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }
        }

        // The crest of the shock wave; the water's own ring is the ripple distortion under the grid.
        context.stroke(
            circle(center, cell * (0.45 + 1.25 * burst) * scale),
            with: .color(Theme.flame.opacity(0.55 * fade)),
            lineWidth: 0.5 + cell * 0.05 * CGFloat(fade)
        )
    }

    private static func drawSplash(
        _ t: Double,
        elapsed: TimeInterval,
        center: CGPoint,
        cell: CGFloat,
        flashes: Bool,
        isClose: Bool,
        in context: inout GraphicsContext
    ) {
        guard t < 1 else { return }
        let reach: CGFloat = isClose ? 0.7 : 1

        // A 60 ms flash dot where the shell struck, with flashes.
        if flashes, elapsed < 0.06 {
            context.fill(circle(center, cell * 0.12), with: .color(Color.white.opacity(0.9 * (1 - elapsed / 0.06))))
        }

        // The column of water: up to 1.3 cells in 180 ms, collapsed by 0.5 s.
        let full = cell * 1.3 * reach
        let height: CGFloat
        if elapsed < 0.18 {
            height = full * CGFloat(easeOut(elapsed / 0.18))
        } else if elapsed < 0.5 {
            height = full * CGFloat(1 - (elapsed - 0.18) / 0.32)
        } else {
            height = 0
        }
        if height > 0 {
            let brightness = flashes ? 0.9 : 0.45
            let width = cell * 0.34 * reach * (0.6 + 0.4 * height / full)
            let column = CGRect(x: center.x - width / 2, y: center.y - height, width: width, height: height)
            context.fill(
                Path(ellipseIn: column),
                with: .linearGradient(
                    Gradient(colors: [Color.white.opacity(brightness), Theme.reticle.opacity(0.35), Theme.reticle.opacity(0.05)]),
                    startPoint: CGPoint(x: center.x, y: column.minY),
                    endPoint: CGPoint(x: center.x, y: column.maxY)
                )
            )
            if flashes {
                let crest = CGRect(x: center.x - width * 0.4, y: column.minY, width: width * 0.8, height: max(1, height * 0.18))
                context.drawLayer { light in
                    light.blendMode = .plusLighter
                    light.fill(Path(ellipseIn: crest), with: .color(Color.white.opacity(0.6)))
                }
            }
        }

        // The base of the column collapsing into the water.
        if t < 0.35 {
            let collapse = 1 - t / 0.35
            let radius = cell * 0.42 * reach * CGFloat(collapse) + 1
            let brightness = flashes ? 0.95 : 0.45
            context.fill(
                circle(center, radius),
                with: .radialGradient(
                    Gradient(colors: [Color.white.opacity(brightness * collapse), Theme.reticle.opacity(0.4 * collapse), Theme.reticle.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func easeOut(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return 1 - (1 - clamped) * (1 - clamped) * (1 - clamped)
    }
}

private struct ShakePose {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var roll: Double = 0
}

/// The shake's beat: six keyframes of this length.
private enum ShakeBeat {
    static let step: TimeInterval = 0.045
}

/// Jolts the view each time `trigger` changes, like a hull taking a hit: sideways by `amplitude`,
/// up and down by `amplitudeY` (0.6 × `amplitude` unless given) and a `roll` of half a degree, each
/// decaying over six 45 ms keyframes. Nothing moves unless the policy allows shakes (the full tier,
/// with the Screen Shake setting on).
struct ShakeEffect: ViewModifier {
    let trigger: Int
    var amplitude: CGFloat = 7
    var amplitudeY: CGFloat?
    var roll: Double = 0.5
    @Environment(\.motionPolicy) private var policy

    func body(content: Content) -> some View {
        let allowed = policy.allowsShake
        let x: CGFloat = allowed ? amplitude : 0
        let y: CGFloat = allowed ? (amplitudeY ?? amplitude * 0.6) : 0
        let tilt: Double = allowed ? roll : 0
        KeyframeAnimator(initialValue: ShakePose(), trigger: trigger) { pose in
            content
                .offset(x: pose.x, y: pose.y)
                .rotationEffect(.degrees(pose.roll))
        } keyframes: { _ in
            KeyframeTrack(\.x) {
                CubicKeyframe(x, duration: ShakeBeat.step)
                CubicKeyframe(-x * 0.8, duration: ShakeBeat.step)
                CubicKeyframe(x * 0.6, duration: ShakeBeat.step)
                CubicKeyframe(-x * 0.4, duration: ShakeBeat.step)
                CubicKeyframe(x * 0.2, duration: ShakeBeat.step)
                CubicKeyframe(0, duration: ShakeBeat.step)
            }
            KeyframeTrack(\.y) {
                CubicKeyframe(-y, duration: ShakeBeat.step)
                CubicKeyframe(y * 0.7, duration: ShakeBeat.step)
                CubicKeyframe(-y * 0.45, duration: ShakeBeat.step)
                CubicKeyframe(y * 0.25, duration: ShakeBeat.step)
                CubicKeyframe(-y * 0.1, duration: ShakeBeat.step)
                CubicKeyframe(0, duration: ShakeBeat.step)
            }
            KeyframeTrack(\.roll) {
                CubicKeyframe(tilt, duration: ShakeBeat.step)
                CubicKeyframe(-tilt * 0.7, duration: ShakeBeat.step)
                CubicKeyframe(tilt * 0.4, duration: ShakeBeat.step)
                CubicKeyframe(-tilt * 0.2, duration: ShakeBeat.step)
                CubicKeyframe(0, duration: ShakeBeat.step * 2)
            }
        }
    }
}

extension View {
    /// Shakes the view each time `trigger` changes: `amplitude` points sideways (4 for a hit landed, 7
    /// for a hit taken, 10 for a sunk), `amplitudeY` up and down, and `roll` degrees of tilt, all
    /// decaying. Only when the policy allows shakes.
    func shakes(on trigger: Int, amplitude: CGFloat = 7, amplitudeY: CGFloat? = nil, roll: Double = 0.5) -> some View {
        modifier(ShakeEffect(trigger: trigger, amplitude: amplitude, amplitudeY: amplitudeY, roll: roll))
    }
}

/// A red pulse around the edges of the screen when the player's fleet is hit, to a peak of 0.75 with
/// a red/cyan split on its edge for the first 120 ms. Without flashes (the reduced and still tiers,
/// Dim Flashing Lights, the Flashes setting off) the edges glow up gently to 0.35 instead.
struct DamageFlash: View {
    let trigger: Int
    @State private var intensity = 0.0
    @State private var isSplitting = false
    @Environment(\.motionPolicy) private var policy

    /// The sharp flash's peak opacity.
    static let peak = 0.75
    /// The gentle variant's.
    static let gentlePeak = 0.35
    /// How far the split samples red and blue from the pixel.
    static let splitOffset = CGSize(width: 3, height: 0)
    /// How long the split lasts after a hit.
    static let splitLength: TimeInterval = 0.12

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
        .layerEffect(
            ShaderEffects.chromaticSplit(offset: isSplitting ? DamageFlash.splitOffset : .zero),
            maxSampleOffset: CGSize(width: 4, height: 4),
            isEnabled: policy.allowsFlashes && isSplitting
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) {
            let isSharp = policy.allowsFlashes
            withAnimation(.easeIn(duration: isSharp ? 0.08 : 0.4)) {
                intensity = isSharp ? DamageFlash.peak : DamageFlash.gentlePeak
            }
            isSplitting = isSharp
            Task {
                if isSharp {
                    try? await Task.sleep(for: .seconds(DamageFlash.splitLength))
                    isSplitting = false
                    try? await Task.sleep(for: .milliseconds(20))
                } else {
                    try? await Task.sleep(for: .milliseconds(450))
                }
                withAnimation(.easeOut(duration: isSharp ? 0.8 : 1.2)) {
                    intensity = 0
                }
            }
        }
    }
}
