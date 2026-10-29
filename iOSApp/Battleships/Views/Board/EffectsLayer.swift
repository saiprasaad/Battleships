import BattleshipCore
import SwiftUI

/// Every live effect on one board, drawn by one timeline and one Canvas: the ring closing on a cell
/// through the last moments of a shell's flight, the bursts where shells landed, the enemy's
/// telegraphed shell (a shadow drifting toward the cell, then the falling streak), the water boiling
/// and the slick spreading under a sinking hull with the chain of secondary blasts along it, the
/// smoke and ember pops of burning cells, the pulse marking the latest shot, the wakes of the fleet
/// sailing in, and the rings of the final blow and of the fleet surfacing after it. It reads the
/// board's `FXClock`, so a hit-stop freezes everything on the board at once and the finale's slow
/// motion stretches it all. Everything is a function of the dates the controller publishes, so a view
/// recreated mid-burst (a size-class swap, the Fleet sheet) resumes at the right frame. Particle lists
/// are built once per effect, seeded by the effect's id, and cached; the timeline pauses when nothing
/// is live and runs at the scenery rate when only smoke is.
struct EffectsLayer: View {
    let geometry: BoardGeometry
    let board: BoardSide
    let controller: BattleController
    /// The mini map: bursts, the telegraph, the marker and the rings only; no bubbles, slick,
    /// secondaries, smoke or wakes.
    var isMiniature = false
    /// The cells of this board that are burning (a hit on a ship still afloat): smoke and ember pops
    /// rise from them on full-size boards, clipped to the cell on the target board.
    var burningCells: [Coordinate] = []
    /// The player's fleet, in sailing order, for the wakes of the sail-in on the full-size home board.
    var fleet: [ShipPlacement] = []
    /// The enemy ships surfacing after the final blow, in the order they rise (the target board).
    var surfacingShips: [ShipPlacement] = []

    @Environment(\.motionPolicy) private var policy
    /// Each impact's particles, by its id.
    @State private var bursts: [UUID: [Particle]] = [:]
    /// Each sinking's bubbles and blasts, by its id.
    @State private var sinkingPlans: [UUID: SinkingPlan] = [:]
    @State private var finalePlan: FinalePlan?
    /// Each burning cell's smoke and embers.
    @State private var smokePlans: [Coordinate: SmokePlan] = [:]
    /// Each sailing ship's wake, and each surfacing ship's rings.
    @State private var wakePlans: [ShipPlacement: [Particle]] = [:]
    @State private var fleetPlans: [ShipPlacement: [Particle]] = [:]
    /// When the latest shot on this board landed, for the marker's pulse; nil shows a static ring.
    @State private var markerStart: Date?
    /// Something is live, so the timeline runs. Cleared once the last effect has played out.
    @State private var isAwake = false

    /// Wall-clock slack past an effect's nominal end, for the hit-stops and slow motion that stretch it.
    static let slack: TimeInterval = 1.2
    /// How long the final blow's rings and the surfacing fleet play, in effect time.
    static let finaleLength: TimeInterval = 4.2
    /// How long the latest shot's marker pulses before it settles to a ring.
    static let markerPulse: TimeInterval = 6
    /// One pulse of the marker.
    static let markerPeriod: TimeInterval = 1.2
    /// From a sinking's start to the hull's reveal rings on the target board.
    static let revealDelay: TimeInterval = 0.12

    var body: some View {
        let shells = controller.shells.filter { $0.board == board }
        let impacts = controller.impacts.filter { $0.board == board }
        let telegraph: Telegraph? = board == .home ? controller.telegraph : nil
        let sinkings = controller.sinkings.filter { $0.board == board }
        let finale: Finale? = controller.finale.flatMap { $0.board == board ? $0 : nil }
        let opening: BattleController.Opening? = board == .home && !isMiniature ? controller.opening : nil
        let latestShot = board == .target ? controller.latestOwnShot : controller.latestEnemyShot
        let showsMarker = latestShot != nil && !(board == .target && controller.aimed != nil)
        let clock = board == .target ? controller.targetClock : controller.homeClock
        let burning = isMiniature || !policy.allowsParticles ? [] : burningCells
        let liveUntil = EffectsLayer.liveUntil(
            shells: shells, impacts: impacts, telegraph: telegraph, sinkings: sinkings, finale: finale,
            opening: opening, markerStart: showsMarker ? markerStart : nil
        )
        let keys = EffectKeys(
            impacts: impacts.map(\.id), sinkings: sinkings.map(\.id), finale: finale?.start,
            burning: burning, fleet: opening == nil ? [] : fleet, surfacing: finale == nil ? [] : surfacingShips
        )
        let smokes = !burning.isEmpty
        let isLive = isAwake || smokes
        let interval = isAwake ? policy.effectsInterval : (policy.sceneryInterval ?? policy.effectsInterval)
        let side = geometry.gutter + geometry.gridSide
        ZStack(alignment: .topLeading) {
            if isLive {
                EffectTimeline(clock: clock, frameInterval: interval) { effectTime in
                    let frame = makeFrame(
                        at: effectTime,
                        clock: clock,
                        shells: shells,
                        impacts: impacts,
                        telegraph: telegraph,
                        sinkings: sinkings,
                        finale: finale,
                        opening: opening,
                        burning: burning,
                        marker: showsMarker ? latestShot : nil
                    )
                    Canvas(rendersAsynchronously: true) { context, _ in
                        EffectsLayer.draw(frame, in: &context)
                    }
                }
            } else if showsMarker, let latestShot {
                // Nothing moves: the marker's ring alone, drawn once.
                Canvas { context, _ in
                    EffectsLayer.drawMarker(center: geometry.center(of: latestShot), cell: geometry.cell, pulse: nil, in: &context)
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
            cachePlans(impacts: impacts, sinkings: sinkings, finale: finale, allImpacts: controller.impacts, burning: burning, fleet: keys.fleet, surfacing: keys.surfacing)
        }
        .onChange(of: latestShot) { _, shot in
            markerStart = shot == nil ? nil : Date()
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

        /// Particles playing from a point: the final blow's rings, a hull surfacing, a wake.
        struct Emission: Sendable {
            var center: CGPoint
            var elapsed: TimeInterval
            var particles: [Particle]
        }

        struct Smoke: Sendable {
            var center: CGPoint
            /// The cell's rect on the target board, where the smoke stays inside its cell.
            var clip: CGRect?
            var elapsed: TimeInterval
            var puffs: [Particle]
            var embers: [Particle]
        }

        struct Marker: Sendable {
            var center: CGPoint
            /// 0…1 through the current pulse; nil once the marker has settled.
            var pulse: Double?
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
        var smokes: [Smoke] = []
        var emissions: [Emission] = []
        var wakes: [Emission] = []
        var marker: Marker?

        /// The moment of a burst the still tier shows.
        static let stillElapsed: TimeInterval = 0.3
    }

    /// Which effects are on the board, so the caches follow the lists.
    private struct EffectKeys: Equatable {
        var impacts: [UUID]
        var sinkings: [UUID]
        var finale: Date?
        var burning: [Coordinate]
        var fleet: [ShipPlacement]
        var surfacing: [ShipPlacement]
    }

    /// A sinking's particles: the bubbles under the hull, a secondary blast for each of its cells, and
    /// the rings of the hull surfacing into view (the target board's reveal).
    struct SinkingPlan: Equatable, Sendable {
        var cells: [Coordinate]
        /// Where the shell that sank it struck; the blasts walk out from here.
        var hitIndex: Int
        var bubbles: [Particle]
        var blasts: [[Particle]]
        var reveal: [Particle]
    }

    struct FinalePlan: Equatable, Sendable {
        var start: Date
        var rings: [Particle]
    }

    /// A burning cell's looping smoke and embers.
    struct SmokePlan: Equatable, Sendable {
        var puffs: [Particle]
        var embers: [Particle]
    }

    private func makeFrame(
        at effectTime: TimeInterval,
        clock: FXClock,
        shells: [ShellFlight],
        impacts: [Impact],
        telegraph: Telegraph?,
        sinkings: [Sinking],
        finale: Finale?,
        opening: BattleController.Opening?,
        burning: [Coordinate],
        marker: Coordinate?
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
                let rect = geometry.rect(for: sinking.ship)
                frame.boils.append(Frame.Boil(rect: rect, elapsed: elapsed, bubbles: plan.bubbles, blasts: blasts))
                // The hull breaking the surface on enemy waters, where it had never been seen.
                if board == .target, !isStill, elapsed >= EffectsLayer.revealDelay {
                    frame.emissions.append(Frame.Emission(center: CGPoint(x: rect.midX, y: rect.midY), elapsed: elapsed - EffectsLayer.revealDelay, particles: plan.reveal))
                }
            }

            for cell in burning {
                guard let plan = smokePlans[cell] else { continue }
                let period = Emitters.smokePeriod
                let looped = period + effectTime.truncatingRemainder(dividingBy: period)
                frame.smokes.append(Frame.Smoke(
                    center: geometry.center(of: cell),
                    clip: board == .target ? geometry.rect(for: cell) : nil,
                    elapsed: looped,
                    puffs: plan.puffs,
                    embers: plan.embers
                ))
            }

            if case let .playing(start)? = opening, !isStill {
                let sailStart = clock.time(at: start)
                for (index, ship) in fleet.enumerated() {
                    let elapsed = effectTime - (sailStart + SailIn.start(of: index))
                    guard elapsed >= 0, elapsed < SailIn.wakeLength, let particles = wakePlans[ship] else { continue }
                    let progress = SailIn.progress(index: index, since: sailStart, at: effectTime)
                    let offset = SailIn.offset(of: ship, geometry: geometry, progress: progress)
                    let stern = SailIn.stern(of: ship, geometry: geometry)
                    frame.wakes.append(Frame.Emission(
                        center: CGPoint(x: stern.x + offset.width, y: stern.y + offset.height),
                        elapsed: elapsed,
                        particles: particles
                    ))
                }
            }
        }

        if let finale {
            let elapsed = effectTime - clock.time(at: finale.start)
            if elapsed >= 0, elapsed < EffectsLayer.finaleLength {
                let cached = finalePlan.flatMap { $0.start == finale.start ? $0.rings : nil }
                frame.emissions.append(Frame.Emission(
                    center: geometry.center(of: finale.coordinate),
                    elapsed: elapsed,
                    particles: cached ?? Emitters.surfaceRings(center: .zero, seed: EffectsLayer.seed(for: finale))
                ))
                if finale.didWin, board == .target, !isStill {
                    for (index, ship) in surfacingShips.enumerated() {
                        let rise = elapsed - (Timing.fleetSurfaceStart + Double(index) * Timing.Stagger.surfacing)
                        guard rise >= 0, let particles = fleetPlans[ship] else { continue }
                        let rect = geometry.rect(for: ship)
                        frame.emissions.append(Frame.Emission(center: CGPoint(x: rect.midX, y: rect.midY), elapsed: rise, particles: particles))
                    }
                }
            }
        }

        if let marker {
            var pulse: Double?
            if !isStill, let markerStart {
                let since = effectTime - clock.time(at: markerStart)
                if since >= 0, since < EffectsLayer.markerPulse {
                    pulse = since.truncatingRemainder(dividingBy: EffectsLayer.markerPeriod) / EffectsLayer.markerPeriod
                }
            }
            frame.marker = Frame.Marker(center: geometry.center(of: marker), pulse: pulse)
        }
        return frame
    }

    /// Fills the caches for the effects now on the board and drops the ones that have gone.
    private func cachePlans(
        impacts: [Impact], sinkings: [Sinking], finale: Finale?, allImpacts: [Impact],
        burning: [Coordinate], fleet: [ShipPlacement], surfacing: [ShipPlacement]
    ) {
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

        var smoke: [Coordinate: SmokePlan] = [:]
        for cell in burning {
            smoke[cell] = smokePlans[cell] ?? EffectsLayer.smokePlan(for: cell, boardSize: geometry.boardSize, isTargetBoard: board == .target)
        }
        if smoke != smokePlans {
            smokePlans = smoke
        }

        var wakes: [ShipPlacement: [Particle]] = [:]
        for ship in fleet {
            wakes[ship] = wakePlans[ship] ?? Emitters.wake(from: .zero, heading: SailIn.heading(of: ship), seed: EffectsLayer.seed(for: ship))
        }
        if wakes != wakePlans {
            wakePlans = wakes
        }

        var rings: [ShipPlacement: [Particle]] = [:]
        for ship in surfacing {
            rings[ship] = fleetPlans[ship] ?? Emitters.surfaceRings(center: .zero, seed: EffectsLayer.seed(for: ship))
        }
        if rings != fleetPlans {
            fleetPlans = rings
        }
    }

    static func kind(of impact: Impact) -> ImpactBurst.Kind {
        if impact.isHit {
            return .detonation
        }
        return impact.isClose ? .closeSplash : .splash
    }

    static func seed(for finale: Finale) -> UInt64 {
        finale.start.timeIntervalSinceReferenceDate.bitPattern ^ UInt64(truncatingIfNeeded: finale.coordinate.hashValue)
    }

    static func seed(for ship: ShipPlacement) -> UInt64 {
        UInt64(truncatingIfNeeded: ship.origin.row &* 31 &+ ship.origin.column &* 7 &+ ship.kind.length &* 131) &* 0x9E37_79B9_7F4A_7C15
    }

    /// A sinking's bubbles, blasts and reveal rings. The blasts walk out from the cell the sinking
    /// shot struck, found among the board's impacts; failing that, from the middle of the hull.
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
        let reveal = Emitters.surfaceRings(center: .zero, seed: ImpactBurst.seed(for: sinking.id, step: cells.count + 1))
        return SinkingPlan(cells: cells, hitIndex: hitIndex, bubbles: bubbles, blasts: blasts, reveal: reveal)
    }

    /// A burning cell's smoke and embers, phased by where it is so neighbours don't puff together.
    static func smokePlan(for cell: Coordinate, boardSize: Int, isTargetBoard: Bool) -> SmokePlan {
        let index = cell.row * max(boardSize, 1) + cell.column
        let phase = Double((cell.row * 7 + cell.column * 3) % 11) / 11 * Emitters.smokePeriod
        return SmokePlan(
            puffs: Emitters.smoke(cell: index, phase: phase, isTargetBoard: isTargetBoard),
            embers: Emitters.emberPops(cell: index, phase: phase + 0.4)
        )
    }

    /// When the last effect on the board will have played out, in wall time, or nil with nothing live.
    static func liveUntil(
        shells: [ShellFlight], impacts: [Impact], telegraph: Telegraph?, sinkings: [Sinking], finale: Finale?,
        opening: BattleController.Opening? = nil, markerStart: Date? = nil
    ) -> Date? {
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
        if case let .playing(start)? = opening {
            extend(start.addingTimeInterval(SailIn.length + slack))
        }
        if let markerStart {
            extend(markerStart.addingTimeInterval(markerPulse))
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
        for smoke in frame.smokes {
            drawSmoke(smoke, frame: frame, in: &context)
        }
        for wake in frame.wakes {
            ParticleRenderer.draw(wake.particles, elapsed: wake.elapsed, unit: cell, at: wake.center, flashes: frame.flashes, budget: frame.budget, in: &context)
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
        if let marker = frame.marker {
            drawMarker(center: marker.center, cell: cell, pulse: marker.pulse, in: &context)
        }
        if let incoming = frame.incoming {
            drawIncoming(incoming, frame: frame, in: &context)
        }
        for emission in frame.emissions {
            ParticleRenderer.draw(emission.particles, elapsed: emission.elapsed, unit: cell, at: emission.center, flashes: frame.flashes, budget: frame.budget, in: &context)
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

    /// A burning cell's smoke (never over 0.35 opacity) and the embers popping off its fire; on the
    /// target board the smoke stays inside the cell's own rect.
    nonisolated private static func drawSmoke(_ smoke: Frame.Smoke, frame: Frame, in context: inout GraphicsContext) {
        var layer = context
        if let clip = smoke.clip {
            layer.clip(to: Path(clip))
        }
        var puffs = layer
        puffs.opacity = 0.8
        ParticleRenderer.draw(smoke.puffs, elapsed: smoke.elapsed, unit: frame.cell, at: smoke.center, flashes: frame.flashes, budget: frame.budget, in: &puffs)
        ParticleRenderer.draw(smoke.embers, elapsed: smoke.elapsed, unit: frame.cell, at: smoke.center, flashes: frame.flashes, budget: frame.budget, in: &layer)
    }

    /// The marker on the latest shot: a cyan ring on the cell and, while it pulses, a ring expanding
    /// out of it.
    nonisolated static func drawMarker(center: CGPoint, cell: CGFloat, pulse: Double?, in context: inout GraphicsContext) {
        context.stroke(
            ParticleRenderer.circle(center, cell * 0.46),
            with: .color(Theme.reticle.opacity(0.55)),
            lineWidth: max(1, cell * 0.04)
        )
        guard let pulse else { return }
        let grow = Particle.easeOut(pulse)
        context.stroke(
            ParticleRenderer.circle(center, cell * (0.3 + 0.6 * CGFloat(grow))),
            with: .color(Theme.reticle.opacity(0.7 * (1 - pulse))),
            lineWidth: max(1, cell * 0.05 * CGFloat(1 - pulse) + 0.5)
        )
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

/// The fleet sailing into its berths at the start of a battle (OPN-2): each ship slides in along its
/// axis from beyond the edge its stern faces, bow first, carrier first, `stagger` apart, over
/// `shipLength` seconds, with a wake behind it on the full-size board. Shared by `HomeBoard` (the
/// ships' offsets) and `EffectsLayer` (the wakes), so both read the same clock.
enum SailIn {
    /// Between ships setting off: 90 ms.
    static let stagger: TimeInterval = Timing.Stagger.ship * 2
    /// One ship's trip into its berth.
    static let shipLength: TimeInterval = 0.7
    /// How long a wake is drawn after a ship sets off.
    static let wakeLength: TimeInterval = 1.8
    /// From the first ship setting off until the last of a full fleet has berthed.
    static var length: TimeInterval { Double(Timing.Stagger.maxItems) * stagger + shipLength }

    /// When the `index`th ship sets off, after the first.
    static func start(of index: Int) -> TimeInterval {
        Double(min(max(0, index), Timing.Stagger.maxItems)) * stagger
    }

    /// How far into its berth the `index`th ship is at `time`, eased, for a sail-in that began at
    /// `since` on the same clock: 0 still beyond the edge, 1 berthed.
    static func progress(index: Int, since: TimeInterval, at time: TimeInterval) -> Double {
        Motion.easeOut(min(1, max(0, (time - since - start(of: index)) / shipLength)))
    }

    /// The way a ship travels: a horizontal ship comes in from the left, a vertical one from the top.
    static func heading(of ship: ShipPlacement) -> SIMD2<Double> {
        ship.orientation == .horizontal ? SIMD2(1, 0) : SIMD2(0, 1)
    }

    /// Where a ship is relative to its berth at `progress`: beyond the water's edge at 0, home at 1.
    static func offset(of ship: ShipPlacement, geometry: BoardGeometry, progress: Double) -> CGSize {
        let rect = geometry.rect(for: ship)
        let grid = geometry.gridRect
        let remaining = CGFloat(1 - min(1, max(0, progress)))
        return ship.orientation == .horizontal
            ? CGSize(width: -(rect.maxX - grid.minX + geometry.cell * 0.5) * remaining, height: 0)
            : CGSize(width: 0, height: -(rect.maxY - grid.minY + geometry.cell * 0.5) * remaining)
    }

    /// The point the wake trails from: the stern end of the ship in its berth.
    static func stern(of ship: ShipPlacement, geometry: BoardGeometry) -> CGPoint {
        let rect = geometry.rect(for: ship)
        return ship.orientation == .horizontal
            ? CGPoint(x: rect.minX + geometry.cell * 0.15, y: rect.midY)
            : CGPoint(x: rect.midX, y: rect.minY + geometry.cell * 0.15)
    }
}
