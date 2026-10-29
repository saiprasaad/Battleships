import SwiftUI

/// The living water under a board: the sea `SeaGrid` once painted, lit from the top left, shaded every
/// frame by the `oceanWater` shader, bent by `rippleDistort` where shells have just landed and marked by
/// `stainWash` where ships burn and shells splashed. It sits under the grid, labels and marks, which
/// stay crisp: this is the only layer that ever distorts.
///
/// Impacts and stains are placed in the board's coordinate space (what `BoardGeometry.center(of:)`
/// gives) and timed on the clock `Motion.seconds(_:)` reads, `Date.timeIntervalSinceReferenceDate`;
/// `ShaderEffects` folds that clock into a 1000 s cycle before it reaches the GPU. The ripple pass runs
/// only while an impact is live and the stain pass only while there are stains. The policy sets the
/// pace: `waterInterval` (24 frames a second, 12 in the reduced tier) or, when it holds loops still,
/// one still frame at `stillSeconds` with no ripples; with `isAnimated` off there is one still frame.
/// `seaState` is animatable: callers change it under `.animation(Motion.Curve.state, value:)`.
struct WaterView: View, Animatable {
    let geometry: BoardGeometry
    /// How rough the water is, from 0 (calm) to 1. Animate changes from the caller with `.animation(_:value:)`.
    var seaState: Double = 0.2
    /// Live ripples; the four newest play.
    var impacts: [WaterImpact] = []
    /// Burning ships (darkening) and splashes (foam). Oil comes first, then the newest foam, four in all.
    var stains: [WaterStain] = []
    /// Off for one still frame: miniatures, Reduce Motion.
    var isAnimated = true
    @Environment(\.motionPolicy) private var policy

    /// The swell's phase in a still frame.
    private static let stillSeconds: TimeInterval = 12.5

    var animatableData: Double {
        get { seaState }
        set { seaState = newValue }
    }

    var body: some View {
        let interval = policy.waterInterval
        let holdsStill = !isAnimated || interval == nil || policy.holdsStill
        let allowsRipples = isAnimated && policy.tier != .still
        let rect = geometry.gridRect
        let cell = geometry.cell
        let cornerRadius = min(14, cell * 0.35)
        TimelineView(.animation(minimumInterval: interval ?? Clocks.flameFrameInterval, paused: holdsStill)) { timeline in
            let now = Motion.seconds(timeline.date)
            let ripples = allowsRipples && !holdsStill ? WaterView.liveImpacts(impacts, at: now, origin: rect.origin) : []
            let marks = WaterView.chosenStains(stains, at: now, settled: holdsStill, origin: rect.origin)
            Color.clear
                .overlay(alignment: .topLeading) {
                    WaterFill(size: rect.size, cornerRadius: cornerRadius)
                        .frame(width: rect.width, height: rect.height)
                        .colorEffect(
                            ShaderEffects.water(time: holdsStill ? WaterView.stillSeconds : now, size: rect.size, seaState: seaState)
                        )
                        .distortionEffect(
                            ShaderEffects.ripples(time: now, size: rect.size, cell: cell, impacts: ripples),
                            maxSampleOffset: CGSize(width: cell * 0.2, height: cell * 0.2),
                            isEnabled: !ripples.isEmpty
                        )
                        .colorEffect(
                            ShaderEffects.stains(time: holdsStill ? WaterView.settledSeconds(for: marks) : now, cell: cell, stains: marks),
                            isEnabled: !marks.isEmpty
                        )
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .offset(x: rect.minX, y: rect.minY)
                }
        }
        .motionBudgeted(isLive: !holdsStill)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The impacts whose rings are playing at `now`, newest first and four at most, moved from the
    /// board's coordinates into the water's.
    private static func liveImpacts(_ impacts: [WaterImpact], at now: TimeInterval, origin: CGPoint) -> [WaterImpact] {
        let live = impacts.filter { now - $0.start >= 0 && now - $0.start < WaterImpact.life }
        return live.sorted { $0.start > $1.start }.prefix(4).map { impact in
            var moved = impact
            moved.x -= origin.x
            moved.y -= origin.y
            return moved
        }
    }

    /// The stains to draw at `now`: oil first (it holds), then the newest foam (it fades), four in all,
    /// moved from the board's coordinates into the water's. A settled frame (the clock holding still)
    /// shows every oil stain full-grown and no foam.
    private static func chosenStains(_ stains: [WaterStain], at now: TimeInterval, settled: Bool, origin: CGPoint) -> [WaterStain] {
        let oil = stains.filter { $0.strength > 0 && (settled || now - $0.start >= 0) }
        let foam = settled ? [] : stains.filter { $0.strength < 0 && now - $0.start >= 0 && now - $0.start < WaterStain.foamLife }
        let chosen = oil.sorted { $0.start > $1.start } + foam.sorted { $0.start > $1.start }
        return chosen.prefix(4).map { stain in
            var moved = stain
            moved.x -= origin.x
            moved.y -= origin.y
            return moved
        }
    }

    /// A shader time at which every one of `stains` has grown to full size.
    private static func settledSeconds(for stains: [WaterStain]) -> TimeInterval {
        (stains.map(\.start).max() ?? 0) + WaterStain.growth + 1
    }
}

/// The still picture of the water: light falling from above into the deep, with a wash from the top
/// left. The shaders animate it, so it is drawn once and kept.
private struct WaterFill: View, Equatable {
    let size: CGSize
    let cornerRadius: CGFloat

    var body: some View {
        Canvas { context, _ in
            WaterFill.draw(size: size, cornerRadius: cornerRadius, in: context)
        }
    }

    private static func draw(size: CGSize, cornerRadius: CGFloat, in context: GraphicsContext) {
        let rect = CGRect(origin: .zero, size: size)
        guard rect.width > 0, rect.height > 0 else { return }
        let water = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)

        // Light falls from above, fading into the deep at the edges.
        context.fill(
            water,
            with: .radialGradient(
                Gradient(colors: [Theme.seaGlow, Theme.seaTop, Theme.seaBottom, Theme.abyss]),
                center: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.3),
                startRadius: 0,
                endRadius: rect.height * 1.05
            )
        )
        context.fill(
            water,
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.09), .white.opacity(0)]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.midY)
            )
        )
    }
}
