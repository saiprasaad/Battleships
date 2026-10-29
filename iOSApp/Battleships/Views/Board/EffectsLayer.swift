import BattleshipCore
import SwiftUI

/// Every live effect on one board, drawn by one timeline and one Canvas: the ring closing on a cell
/// through the last moments of a shell's flight, the bursts where shells landed, the enemy's
/// telegraphed shell (a shadow drifting toward the cell, then the falling streak), the water boiling
/// and the slick spreading under a sinking hull with the chain of secondary blasts along it, and the
/// rings of the final blow. It reads the board's `FXClock`, so a hit-stop freezes everything on the
/// board at once and the finale's slow motion stretches it all. Everything is a function of the dates
/// the controller publishes, so a view recreated mid-burst (a size-class swap, the Fleet sheet)
/// resumes at the right frame. Particle lists are built once per effect, seeded by the effect's id,
/// and cached; the timeline pauses when nothing is live.
struct EffectsLayer: View {
    let geometry: BoardGeometry
    let board: BoardSide
    let controller: BattleController
    /// The mini map: bursts, the telegraph and the rings only; no bubbles, slick or secondaries.
    var isMiniature = false

    @Environment(\.motionPolicy) private var policy
    /// Each impact's particles, by its id.
    @State private var bursts: [UUID: [Particle]] = [:]
    /// Each sinking's bubbles and blasts, by its id.
    @State private var sinkingPlans: [UUID: SinkingPlan] = [:]
    @State private var finalePlan: FinalePlan?
    /// Something is live, so the timeline runs. Cleared once the last effect has played out.
    @State private var isAwake = false

    /// Wall-clock slack past an effect's nominal end, for the hit-stops and slow motion that stretch it.
    static let slack: TimeInterval = 1.2
    /// How long the final blow's rings play.
    static let finaleLength: TimeInterval = 2

    var body: some View {
        let shells = controller.shells.filter { $0.board == board }
        let impacts = controller.impacts.filter { $0.board == board }
        let telegraph: Telegraph? = board == .home ? controller.telegraph : nil
        let sinkings = controller.sinkings.filter { $0.board == board }
        let finale: Finale? = controller.finale.flatMap { $0.board == board ? $0 : nil }
        let clock = board == .target ? controller.targetClock : controller.homeClock
        let liveUntil = EffectsLayer.liveUntil(shells: shells, impacts: impacts, telegraph: telegraph, sinkings: sinkings, finale: finale)
        let keys = EffectKeys(impacts: impacts.map(\.id), sinkings: sinkings.map(\.id), finale: finale?.start)
        let side = geometry.gutter + geometry.gridSide
        ZStack(alignment: .topLeading) {
            if isAwake, liveUntil != nil {
                EffectTimeline(clock: clock, frameInterval: policy.effectsInterval) { effectTime in
                    let frame = makeFrame(
                        at: effectTime,
                        clock: clock,
                        shells: shells,
                        impacts: impacts,
                        telegraph: telegraph,
                        sinkings: sinkings,
                        finale: finale
                    )
                    Canvas(rendersAsynchronously: true) { context, _ in
                        EffectsLayer.draw(frame, in: &context)
                    }
                }
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .task(id: liveUntil) {
            // Wakes the timeline while something is live and lets it sleep once the last effect is over.
            guard let liveUntil else {
                isAwake = false
                return
            }
            isAwake = true
            let remaining = liveUntil.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            isAwake = false
        }
        .onChange(of: keys, initial: true) { _, _ in
            cachePlans(impacts: impacts, sinkings: sinkings, finale: finale, allImpacts: controller.impacts)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: The frame

    /// What one frame draws, in points, with every time in the board's effect seconds. Sendable, so the
    /// Canvas captures nothing else.
    struct Frame: Sendable {
        struct Ring: Sendable {
            var center: CGPoint
            var progress: Double
        }

        struct Burst: Sendable {
            var center: CGPoint
            var kind: ImpactBurst.Kind
            var elapsed: TimeInterval
            var particles: [Particle]
        }

        struct Incoming: Sendable {
            var target: CGPoint
            /// 0…1 from the telegraph's start to the landing.
            var progress: Double
            /// 0…1 through the falling streak, in the last `Timing.incomingStreak` seconds; nil before.
            var streak: Double?
        }

        struct Boil: Sendable {
            var rect: CGRect
            var elapsed: TimeInterval
            var bubbles: [Particle]
            var blasts: [Burst]
        }

        struct Surfacing: Sendable {
            var center: CGPoint
            var elapsed: TimeInterval
            var particles: [Particle]
        }

        var cell: CGFloat
        var gridRect: CGRect
        var flashes: Bool
        var budget: Int
        var isMiniature: Bool
        /// The still tier: one frame, with a burst shown landed and the telegraph as a dim ring.
        var isStill: Bool
        var rings: [Ring] = []
        var bursts: [Burst] = []
        var incoming: Incoming?
        var boils: [Boil] = []
        var finale: Surfacing?

        /// The moment of a burst the still tier shows.
        static let stillElapsed: TimeInterval = 0.3
    }

    /// Which effects are on the board, so the caches follow the lists.
    private struct EffectKeys: Equatable {
        var impacts: [UUID]
        var sinkings: [UUID]
        var finale: Date?
    }

    /// A sinking's particles: the bubbles under the hull, and a secondary blast for each of its cells.
    struct SinkingPlan: Equatable, Sendable {
        var cells: [Coordinate]
        /// Where the shell that sank it struck; the blasts walk out from here.
        var hitIndex: Int
        var bubbles: [Particle]
        var blasts: [[Particle]]
    }

    struct FinalePlan: Equatable, Sendable {
        var start: Date
        var rings: [Particle]
    }

    private func makeFrame(
        at effectTime: TimeInterval,
        clock: FXClock,
        shells: [ShellFlight],
        impacts: [Impact],
        telegraph: Telegraph?,
        sinkings: [Sinking],
        finale: Finale?
    ) -> Frame {
        let isStill = policy.tier == .still
        var frame = Frame(
            cell: geometry.cell,
            gridRect: geometry.gridRect,
            flashes: policy.allowsFlashes,
            budget: policy.allowsParticles ? policy.particleBudget : 0,
            isMiniature: isMiniature,
            isStill: isStill
        )

        for shell in shells {
            guard let lands = shell.lands, shell.outcome != .misfire else { continue }
            let remaining = clock.time(at: lands) - effectTime
            guard remaining >= 0, remaining <= ImpactBurst.closingRing else { continue }
            frame.rings.append(Frame.Ring(center: geometry.center(of: shell.coordinate), progress: 1 - remaining / ImpactBurst.closingRing))
        }

        for impact in impacts {
            let elapsed = effectTime - clock.time(at: impact.start)
            guard elapsed >= 0 else { continue }
            let kind = EffectsLayer.kind(of: impact)
            frame.bursts.append(Frame.Burst(
                center: geometry.center(of: impact.coordinate),
                kind: kind,
                elapsed: isStill ? Frame.stillElapsed : elapsed,
                particles: bursts[impact.id] ?? ImpactBurst.particles(kind: kind, seed: ImpactBurst.seed(for: impact.id))
            ))
        }

        if let telegraph {
            let start = clock.time(at: telegraph.start)
            let lands = clock.time(at: telegraph.lands)
            let span = max(0.001, lands - start)
            let progress = min(1, max(0, (effectTime - start) / span))
            let untilLanding = lands - effectTime
            let streak: Double? = untilLanding <= Timing.incomingStreak
                ? min(1, max(0, 1 - untilLanding / Timing.incomingStreak))
                : nil
            frame.incoming = Frame.Incoming(target: geometry.center(of: telegraph.coordinate), progress: progress, streak: streak)
        }

        if !isMiniature {
            for sinking in sinkings {
                let elapsed = effectTime - clock.time(at: sinking.start)
                guard elapsed >= 0 else { continue }
                let plan = sinkingPlans[sinking.id] ?? EffectsLayer.plan(for: sinking, impacts: impacts)
                var blasts: [Frame.Burst] = []
                for (index, cell) in plan.cells.enumerated() where index != plan.hitIndex && index < plan.blasts.count {
                    let step = abs(index - plan.hitIndex)
                    let blastElapsed = elapsed - (Timing.listStart + Double(step) * Timing.secondaryStep)
                    guard blastElapsed >= 0, blastElapsed < ImpactBurst.particleTail else { continue }
                    blasts.append(Frame.Burst(
                        center: geometry.center(of: cell),
                        kind: .secondary,
                        elapsed: isStill ? Frame.stillElapsed : blastElapsed,
                        particles: plan.blasts[index]
                    ))
                }
                frame.boils.append(Frame.Boil(rect: geometry.rect(for: sinking.ship), elapsed: elapsed, bubbles: plan.bubbles, blasts: blasts))
            }
        }

        if let finale {
            let elapsed = effectTime - clock.time(at: finale.start)
            if elapsed >= 0, elapsed < EffectsLayer.finaleLength {
                let cached = finalePlan.flatMap { $0.start == finale.start ? $0.rings : nil }
                frame.finale = Frame.Surfacing(
                    center: geometry.center(of: finale.coordinate),
                    elapsed: elapsed,
                    particles: cached ?? Emitters.surfaceRings(center: .zero, seed: EffectsLayer.seed(for: finale))
                )
            }
        }
        return frame
    }

    /// Fills the caches for the effects now on the board and drops the ones that have gone.
    private func cachePlans(impacts: [Impact], sinkings: [Sinking], finale: Finale?, allImpacts: [Impact]) {
        var kept: [UUID: [Particle]] = [:]
        for impact in impacts {
            kept[impact.id] = bursts[impact.id] ?? ImpactBurst.particles(kind: EffectsLayer.kind(of: impact), seed: ImpactBurst.seed(for: impact.id))
        }
        if kept != bursts {
            bursts = kept
        }

        var plans: [UUID: SinkingPlan] = [:]
        if !isMiniature {
            for sinking in sinkings {
                plans[sinking.id] = sinkingPlans[sinking.id] ?? EffectsLayer.plan(for: sinking, impacts: allImpacts)
            }
        }
        if plans != sinkingPlans {
            sinkingPlans = plans
        }

        if let finale {
            if finalePlan?.start != finale.start {
                finalePlan = FinalePlan(start: finale.start, rings: Emitters.surfaceRings(center: .zero, seed: EffectsLayer.seed(for: finale)))
            }
        } else if finalePlan != nil {
            finalePlan = nil
        }
    }

    static func kind(of impact: Impact) -> ImpactBurst.Kind {
        impact.isHit ? .detonation : .splash
    }

    static func seed(for finale: Finale) -> UInt64 {
        finale.start.timeIntervalSinceReferenceDate.bitPattern ^ UInt64(truncatingIfNeeded: finale.coordinate.hashValue)
    }

    /// A sinking's bubbles and blasts. The blasts walk out from the cell the sinking shot struck,
    /// found among the board's impacts; failing that, from the middle of the hull.
    static func plan(for sinking: Sinking, impacts: [Impact]) -> SinkingPlan {
        let ship = sinking.ship
        let cells = ship.cells
        let hit = impacts.first { $0.board == sinking.board && $0.isSunk && ship.contains($0.coordinate) }
        let hitIndex = hit.flatMap { impact in cells.firstIndex(of: impact.coordinate) } ?? cells.count / 2
        let isHorizontal = ship.orientation == .horizontal
        let width = Double(isHorizontal ? cells.count : 1)
        let height = Double(isHorizontal ? 1 : cells.count)
        let seed = ImpactBurst.seed(for: sinking.id)
        let bubbles = Emitters.boil(rect: SIMD4(-width / 2, -height / 2, width, height), seed: seed)
        let blasts = cells.indices.map { index in
            Emitters.detonation(seed: ImpactBurst.seed(for: sinking.id, step: index + 1), scale: 0.55, isPrimary: false)
        }
        return SinkingPlan(cells: cells, hitIndex: hitIndex, bubbles: bubbles, blasts: blasts)
    }

    /// When the last effect on the board will have played out, in wall time, or nil with nothing live.
    static func liveUntil(shells: [ShellFlight], impacts: [Impact], telegraph: Telegraph?, sinkings: [Sinking], finale: Finale?) -> Date? {
        var until: Date?
        func extend(_ date: Date) {
            until = until.map { max($0, date) } ?? date
        }
        for shell in shells {
            // A shell held at the apex has nothing to draw until its landing is known; the list changes then.
            if let lands = shell.lands, shell.outcome != .misfire {
                extend(lands.addingTimeInterval(slack))
            }
        }
        for impact in impacts {
            extend(impact.start.addingTimeInterval(ImpactBurst.particleTail + slack))
        }
        if let telegraph {
            extend(telegraph.lands.addingTimeInterval(0.3))
        }
        for sinking in sinkings {
            extend(sinking.start.addingTimeInterval(Timing.sinking + slack))
        }
        if let finale {
            extend(finale.start.addingTimeInterval(finaleLength + slack))
        }
        return until
    }

    // MARK: Drawing

    // Off the main actor: the Canvas renders asynchronously and the frame carries everything it needs.

    nonisolated static func draw(_ frame: Frame, in context: inout GraphicsContext) {
        let cell = frame.cell
        guard cell > 0 else { return }
        for ring in frame.rings {
            ImpactBurst.drawClosingRing(progress: ring.progress, cell: cell, at: ring.center, in: &context)
        }
        for boil in frame.boils {
            drawBoil(boil, frame: frame, in: &context)
        }
        for burst in frame.bursts {
            ImpactBurst.draw(
                kind: burst.kind,
                elapsed: burst.elapsed,
                particles: burst.particles,
                cell: cell,
                flashes: frame.flashes,
                at: burst.center,
                budget: frame.budget,
                in: &context
            )
        }
        if let incoming = frame.incoming {
            drawIncoming(incoming, frame: frame, in: &context)
        }
        if let finale = frame.finale {
            ParticleRenderer.draw(finale.particles, elapsed: finale.elapsed, unit: cell, at: finale.center, flashes: frame.flashes, budget: frame.budget, in: &context)
        }
    }

    /// The slick spreading under a sinking hull from `Timing.listStart`, the bubbles, and the chain
    /// of blasts along it.
    nonisolated private static func drawBoil(_ boil: Frame.Boil, frame: Frame, in context: inout GraphicsContext) {
        let cell = frame.cell
        let rect = boil.rect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let grow = Particle.easeOut((boil.elapsed - Timing.listStart) / 1.6)
        if grow > 0 {
            let spread = CGFloat(0.3 + 0.95 * grow)
            let slick = CGRect(
                x: center.x - rect.width * spread / 2,
                y: center.y - rect.height * spread / 2,
                width: rect.width * spread,
                height: rect.height * spread
            )
            context.fill(
                Path(ellipseIn: slick),
                with: .radialGradient(
                    Gradient(colors: [Color.black.opacity(0.38), Theme.abyss.opacity(0.3), Color.black.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: max(slick.width, slick.height) / 2
                )
            )
        }
        ParticleRenderer.draw(boil.bubbles, elapsed: boil.elapsed, unit: cell, at: center, flashes: frame.flashes, budget: frame.budget, in: &context)
        for blast in boil.blasts {
            ImpactBurst.draw(
                kind: blast.kind,
                elapsed: blast.elapsed,
                particles: blast.particles,
                cell: cell,
                flashes: frame.flashes,
                at: blast.center,
                budget: frame.budget,
                in: &context
            )
        }
    }

    /// The enemy's shell on its way: a shadow blot drifting from the top left of the water onto the
    /// cell over the telegraph, then the streak falling onto it through its last `Timing.incomingStreak`
    /// seconds. The still tier shows a dim ring on the cell instead.
    nonisolated private static func drawIncoming(_ incoming: Frame.Incoming, frame: Frame, in context: inout GraphicsContext) {
        let cell = frame.cell
        let grid = frame.gridRect
        let target = incoming.target
        if frame.isStill {
            context.stroke(
                ParticleRenderer.circle(target, cell * 0.42),
                with: .color(Color.black.opacity(0.35)),
                lineWidth: max(1.5, cell * 0.08)
            )
            return
        }

        let drift = CGFloat(Particle.easeOut(incoming.progress))
        let from = CGPoint(
            x: max(grid.minX + cell * 0.5, target.x - cell * 2.2),
            y: max(grid.minY + cell * 0.5, target.y - cell * 2.2)
        )
        let blot = CGPoint(x: from.x + (target.x - from.x) * drift, y: from.y + (target.y - from.y) * drift)
        let radius = cell * (0.55 - 0.15 * drift)
        let opacity = 0.3 * min(1, incoming.progress / 0.15)
        context.fill(
            ParticleRenderer.circle(blot, radius),
            with: .radialGradient(
                Gradient(colors: [Color.black.opacity(opacity), Color.black.opacity(opacity * 0.6), Color.black.opacity(0)]),
                center: blot,
                startRadius: 0,
                endRadius: radius
            )
        )

        if let streak = incoming.streak {
            let top = grid.minY
            let head = CGPoint(x: target.x, y: top + (target.y - top) * CGFloat(streak))
            let tail = CGPoint(x: target.x, y: max(top, head.y - cell * 1.6))
            var path = Path()
            path.move(to: tail)
            path.addLine(to: head)
            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [Color.white.opacity(0), Color.white.opacity(frame.flashes ? 0.95 : 0.5)]),
                    startPoint: tail,
                    endPoint: head
                ),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
        }
    }
}
