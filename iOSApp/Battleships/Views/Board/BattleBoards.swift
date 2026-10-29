import BattleshipCore
import SwiftUI

/// The enemy's waters: where the player aims and fires. Everything on it reads the controller's
/// timeline: a cell's mark and a sunk hull appear when the shell lands, the board leans toward the
/// aimed cell while a shell flies and punches as it lands, the bezel sweeps as the turn leaves and
/// returns, the water calms on the player's turn and roughens while they wait, and after the final
/// blow the enemy's unfound fleet surfaces.
struct TargetBoard: View {
    let perspective: BattlePerspective
    let aimed: Coordinate?
    /// The battle's direction: the shells in the air and the effects on this board.
    let controller: BattleController
    let isInteractive: Bool
    let onTap: @MainActor (Coordinate) -> Void
    @Environment(\.motionPolicy) private var policy
    @State private var ledger = LandingLedger()
    /// Bumped on a second tap on the aimed cell: the reticle's brackets clench.
    @State private var squeezes = 0
    /// Bumped on a tap on a cell already fired at: the reticle shakes.
    @State private var refusals = 0
    /// Bumped at the final stamp of a won battle: the gold sweep.
    @State private var finaleSweeps = 0
    /// The board leans 1.12 toward the final blow through its slow motion.
    @State private var isFinaleLeaning = false

    /// How far the board leans toward a cell its shell is heading for, and toward the final blow.
    static let lean: CGFloat = 1.035
    static let finaleLean: CGFloat = 1.12
    /// The water's state on the player's turn, and while they wait.
    static let calmSea = 0.2
    static let waitingSea = 0.5

    var body: some View {
        // The aim shows only while the player can fire, so it doesn't linger once the game ends.
        let aim = isInteractive ? aimed : nil
        let hidden = controller.cellsAwaitingLanding(on: .target, at: Date())
        let shells = controller.shells.filter { $0.board == .target && $0.outcome != .misfire }
        let hasShellInFlight = !shells.isEmpty
        // The board stays lit through the player's own shell's flight: the turn leaves at its landing.
        let isLit = isInteractive || hasShellInFlight
        let finale = controller.finale.flatMap { $0.board == .target ? $0 : nil }
        let stamps = controller.stamps.filter { $0.board == .target }
        let finaleStampID = finale == nil ? nil : stamps.last?.id
        let flareStart = finale == nil ? nil : stamps.last.map { Motion.seconds($0.start) }
        // A cell's result stays a secret while its shell is in the air, and a hull whose last cell
        // hasn't landed is still unknown.
        let shots = perspective.myShots.filter { !hidden.contains($0.target) }
        let known = perspective.knownEnemyShips.filter { ship in !ship.cells.contains { hidden.contains($0) } }
        let sunk = known.filter { perspective.isEnemyShipSunk($0) }
        let afloat = known.filter { !perspective.isEnemyShipSunk($0) }
        let damage: [ShipPlacement: ShipDamage] = known.reduce(into: [:]) { damage, ship in
            damage[ship] = ShipDamage.of(ship, isSunk: perspective.isEnemyShipSunk(ship)) { displayedMark(at: $0, hidden: hidden) }
        }
        let burning = shots.filter { $0.result.isHit }.map(\.target).filter { displayedMark(at: $0, hidden: hidden) == .hit }
        let seaState = isLit ? Self.calmSea : Self.waitingSea
        let leanCell = shells.first?.coordinate ?? finale?.coordinate ?? controller.latestOwnShot
        let leanScale: CGFloat = policy.tier == .still ? 1 : (hasShellInFlight ? Self.lean : (isFinaleLeaning ? Self.finaleLean : 1))
        let boardImpacts = controller.impacts.filter { $0.board == .target }
        let shellIDs = shells.map(\.id)
        BoardView(
            rules: perspective.rules,
            highlighted: aim,
            accent: isLit ? Theme.reticle : nil,
            isDimmed: !isLit && !perspective.isFinished,
            seaState: seaState,
            impacts: ledger.impacts,
            stains: ledger.stains
        ) { geometry in
            if let aim {
                AimGuides(geometry: geometry, target: aim)
                    .transition(.opacity)
            }

            ShipsLayer(
                geometry: geometry,
                board: .target,
                controller: controller,
                ships: known,
                damage: damage,
                isMiniature: false,
                opening: nil,
                arrival: nil,
                finale: finale,
                fateShips: finale?.didWin == true ? afloat : []
            )

            ForEach(shots.filter { !$0.result.isHit }, id: \.target) { move in
                if let mark = displayedMark(at: move.target, hidden: hidden) {
                    CellMarkView(mark: mark, cell: geometry.cell)
                        .position(geometry.center(of: move.target))
                }
            }
            FlameClock(isBurning: shots.contains { $0.result.isHit }) { time in
                ForEach(shots.filter { $0.result.isHit }, id: \.target) { move in
                    if let mark = displayedMark(at: move.target, hidden: hidden) {
                        CellMarkView(mark: mark, cell: geometry.cell, showsHitGlow: mark == .hit, time: time, flareStart: flareStart)
                            .position(geometry.center(of: move.target))
                    }
                }
            }

            EffectsLayer(
                geometry: geometry,
                board: .target,
                controller: controller,
                burningCells: burning,
                surfacingShips: finale?.didWin == true ? afloat : []
            )
            .onChange(of: boardImpacts, initial: true) { _, impacts in
                ledger.noteLandings(impacts, geometry: geometry)
            }
            .onChange(of: shellIDs, initial: true) { _, ids in
                ledger.noteShells(ids)
            }

            // The turn's passage: a cloud shadow as the shot goes, the bezel and grid sweeps as the
            // turn leaves and returns, gold at the end of a won battle.
            CloudPass(geometry: geometry, trigger: ledger.firings)
            GridSweep(geometry: geometry, trigger: controller.turnStings)
            TurnBezelSweep(geometry: geometry, tint: Theme.reticle, trigger: controller.turnStings, clockwise: true)
            TurnBezelSweep(geometry: geometry, tint: Color.white.opacity(0.4), trigger: controller.latestOwnShot, clockwise: false)
            TurnBezelSweep(geometry: geometry, tint: Theme.gold, trigger: finaleSweeps, clockwise: true)

            if let aim {
                ReticleView(geometry: geometry, target: aim, squeeze: squeezes, refusal: refusals)
                    .position(geometry.center(of: aim))
                    .transition(.asymmetric(
                        insertion: .scale(scale: 1.6).combined(with: .opacity),
                        removal: .scale(scale: 0.8).combined(with: .opacity)
                    ))
            }

            ForEach(stamps) { stamp in
                let rect = geometry.rect(for: stamp.ship)
                StampView(text: "SUNK", trigger: stamp.id)
                    .frame(width: max(rect.width, rect.height, geometry.cell * 3), height: geometry.cell * 1.2)
                    .position(x: rect.midX, y: rect.midY)
            }

            // The cells the battle's overlays aim at: the aimed cell and every cell a shell is heading for.
            ForEach(Self.anchoredCells(aim: aim, shells: shells), id: \.self) { cell in
                Color.clear
                    .frame(width: geometry.cell, height: geometry.cell)
                    .battleAnchor(.targetCell(cell))
                    .position(geometry.center(of: cell))
                    .allowsHitTesting(false)
            }

            CellTargets(geometry: geometry, rules: perspective.rules) { coordinate in
                CellTargets.Description(
                    value: targetDescription(at: coordinate, aim: aim),
                    hint: isInteractive && perspective.canTarget(coordinate)
                        ? (aim == coordinate ? "Double-tap to fire." : "Double-tap to aim here.")
                        : nil
                )
            } onTap: { coordinate in
                guard isInteractive else { return }
                if aim == coordinate {
                    squeezes += 1
                } else if !perspective.canTarget(coordinate) {
                    refusals += 1
                }
                onTap(coordinate)
            }
        }
        .battleAnchor(.targetBoard)
        .landingPunch(on: ledger.landings)
        // On top of the host's landing shake (4), so a sunk totals 10.
        .shakes(on: ledger.sunkLandings, amplitude: 6, amplitudeY: 3, roll: 1)
        .scaleEffect(leanScale, anchor: Self.leanAnchor(for: leanCell, rules: perspective.rules))
        .animation(leanScale > 1 ? Motion.Curve.snap.policy(policy) : Motion.Curve.settle.policy(policy), value: leanScale)
        .animation(Motion.Curve.state.policy(policy), value: seaState)
        .animation(Motion.Curve.state.policy(policy), value: isLit)
        .animation(Motion.Curve.snap.policy(policy), value: aim)
        .animation(Motion.Curve.fade.policy(policy), value: known)
        .onChange(of: finaleStampID) { _, id in
            if id != nil {
                finaleSweeps += 1
            }
        }
        .task(id: finale?.start) {
            // The lean toward the final blow lasts through its hit-stop and slow motion.
            guard finale != nil, policy.tier == .full else {
                isFinaleLeaning = false
                return
            }
            isFinaleLeaning = true
            try? await Task.sleep(for: .seconds(Timing.finalHitStop + Timing.finalSlowMotion))
            guard !Task.isCancelled else { return }
            isFinaleLeaning = false
        }
    }

    /// The mark to draw at `coordinate`: none while its shell is in the air, and a hit rather than a
    /// sunk while another cell of the same hull is still awaiting its landing (the sinking lands then).
    private func displayedMark(at coordinate: Coordinate, hidden: Set<Coordinate>) -> CellMark? {
        guard !hidden.contains(coordinate), let mark = perspective.targetMark(at: coordinate) else { return nil }
        if mark == .sunk, let ship = perspective.knownEnemyShip(at: coordinate), ship.cells.contains(where: { hidden.contains($0) }) {
            return .hit
        }
        return mark
    }

    private static func anchoredCells(aim: Coordinate?, shells: [ShellFlight]) -> [Coordinate] {
        var cells = Set(shells.map(\.coordinate))
        if let aim {
            cells.insert(aim)
        }
        return cells.sorted()
    }

    /// Where on the board a cell sits, as the anchor of the lean toward it; the centre without one.
    private static func leanAnchor(for cell: Coordinate?, rules: Rules) -> UnitPoint {
        guard let cell else { return .center }
        let side: CGFloat = 300
        let geometry = BoardGeometry(boardSize: rules.boardSize, side: side, showsLabels: true)
        let center = geometry.center(of: cell)
        return UnitPoint(x: center.x / side, y: center.y / side)
    }

    private func targetDescription(at coordinate: Coordinate, aim: Coordinate?) -> String {
        switch perspective.targetMark(at: coordinate) {
        case .miss: return "Miss"
        case .hit: return "Hit"
        case .sunk:
            let kind = perspective.knownEnemyShip(at: coordinate)?.kind.displayName ?? "ship"
            return "Sunk \(kind)"
        case nil:
            if let ship = perspective.knownEnemyShip(at: coordinate) {
                return "Enemy \(ship.kind.displayName), not hit"
            }
            return aim == coordinate ? "Aimed, not fired at yet" : "Not fired at yet"
        }
    }
}

/// The player's own waters: their fleet and the enemy's shots against it. The fleet sails into its
/// berths at the opening, rides the swell at anchor on full-size boards, takes craters and a list as
/// it is hit, goes under when sunk, and at a lost finale the wrecks darken one after another. The
/// water roughens and darkens while the enemy's shell is on its way.
struct HomeBoard: View {
    let perspective: BattlePerspective
    /// The battle's direction: the enemy's telegraphed shell and the effects on this board.
    let controller: BattleController
    /// The miniature in the battle header has no labels and is a single button, not 100 cells.
    var isMiniature = false
    /// The enemy is lining up a shot: a red sweep crosses the water.
    var isUnderFire = false
    /// Where the fleet's sail-in has got to, 0…1, when the host drives it (OPN-2); nil follows
    /// `controller.opening` on the board's own clock.
    var arrival: Double? = nil
    @Environment(\.motionPolicy) private var policy
    @State private var ledger = LandingLedger()
    /// Bumped at the final stamp of a lost battle: the red sweep.
    @State private var finaleSweeps = 0

    /// The water's state on the player's turn, while they wait, and under the enemy's telegraph.
    static let calmSea = 0.2
    static let waitingSea = 0.5
    static let telegraphSea = 0.9
    /// The wash over the water while the enemy's shell is on its way.
    static let incomingWash = 0.2

    var body: some View {
        let hidden = controller.cellsAwaitingLanding(on: .home, at: Date())
        let telegraph = controller.telegraph
        let finale = controller.finale.flatMap { $0.board == .home ? $0 : nil }
        let stamps = controller.stamps.filter { $0.board == .home }
        let finaleStampID = finale == nil ? nil : stamps.last?.id
        let flareStart = finale == nil ? nil : stamps.last.map { Motion.seconds($0.start) }
        // The enemy's result stays a secret until its telegraphed shell lands.
        let shots = perspective.enemyShots.filter { !hidden.contains($0.target) }
        let fleet = perspective.myFleet
        let damage: [ShipPlacement: ShipDamage] = fleet.reduce(into: [:]) { damage, ship in
            let isSunk = perspective.isMyShipSunk(ship) && !ship.cells.contains { hidden.contains($0) }
            damage[ship] = ShipDamage.of(ship, isSunk: isSunk) { displayedMark(at: $0, hidden: hidden) }
        }
        let burning = isMiniature ? [] : shots.filter { $0.result.isHit }.map(\.target).filter { displayedMark(at: $0, hidden: hidden) == .hit }
        let seaState = telegraph != nil ? Self.telegraphSea : (isUnderFire ? Self.waitingSea : Self.calmSea)
        let wash = telegraph != nil ? Self.incomingWash : 0
        let sweepPeriod = telegraph != nil ? 1.2 : 2.4
        let boardImpacts = controller.impacts.filter { $0.board == .home }
        // At a lost finale the wrecks already down darken and list one after another.
        let fateShips = finale.map { finale in fleet.filter { perspective.isMyShipSunk($0) && !$0.contains(finale.coordinate) } } ?? []
        BoardView(
            rules: perspective.rules,
            showsLabels: !isMiniature,
            accent: !isMiniature && isUnderFire ? Theme.hit : nil,
            seaState: seaState,
            impacts: ledger.impacts,
            stains: ledger.stains,
            isWaterAnimated: !isMiniature
        ) { geometry in
            Rectangle()
                .fill(Color.black.opacity(wash))
                .frame(width: geometry.gridSide, height: geometry.gridSide)
                .clipShape(RoundedRectangle(cornerRadius: min(14, geometry.cell * 0.35), style: .continuous))
                .position(x: geometry.gridRect.midX, y: geometry.gridRect.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            ShipsLayer(
                geometry: geometry,
                board: .home,
                controller: controller,
                ships: fleet,
                damage: damage,
                isMiniature: isMiniature,
                opening: controller.opening,
                arrival: arrival,
                finale: finale,
                fateShips: fateShips
            )

            ForEach(shots.filter { !$0.result.isHit }, id: \.target) { move in
                if let mark = displayedMark(at: move.target, hidden: hidden) {
                    CellMarkView(mark: mark, cell: geometry.cell, isMiniature: isMiniature)
                        .position(geometry.center(of: move.target))
                }
            }
            // The miniature draws hits as craters, which don't flicker.
            FlameClock(isBurning: !isMiniature && shots.contains { $0.result.isHit }) { time in
                ForEach(shots.filter { $0.result.isHit }, id: \.target) { move in
                    if let mark = displayedMark(at: move.target, hidden: hidden) {
                        CellMarkView(mark: mark, cell: geometry.cell, isMiniature: isMiniature, time: time, flareStart: flareStart)
                            .position(geometry.center(of: move.target))
                    }
                }
            }

            if isUnderFire {
                SonarSweep(tint: Theme.hit, period: sweepPeriod)
                    .frame(width: geometry.gridSide, height: geometry.gridSide)
                    .clipShape(RoundedRectangle(cornerRadius: min(14, geometry.cell * 0.35), style: .continuous))
                    .position(x: geometry.gridRect.midX, y: geometry.gridRect.midY)
                    .transition(.opacity)
            }

            EffectsLayer(
                geometry: geometry,
                board: .home,
                controller: controller,
                isMiniature: isMiniature,
                burningCells: burning,
                fleet: isMiniature ? [] : fleet
            )
            .onChange(of: boardImpacts, initial: true) { _, impacts in
                ledger.noteLandings(impacts, geometry: geometry)
            }

            if !isMiniature {
                TurnBezelSweep(geometry: geometry, tint: Theme.hit, trigger: finaleSweeps, clockwise: true)

                ForEach(stamps) { stamp in
                    let rect = geometry.rect(for: stamp.ship)
                    StampView(text: "SUNK", trigger: stamp.id)
                        .frame(width: max(rect.width, rect.height, geometry.cell * 3), height: geometry.cell * 1.2)
                        .position(x: rect.midX, y: rect.midY)
                }
            }

            if !isMiniature, let awaited = telegraph?.coordinate ?? controller.latestEnemyShot {
                Color.clear
                    .frame(width: geometry.cell, height: geometry.cell)
                    .battleAnchor(.homeCell(awaited))
                    .position(geometry.center(of: awaited))
                    .allowsHitTesting(false)
            }

            if !isMiniature {
                CellTargets(geometry: geometry, rules: perspective.rules) { coordinate in
                    CellTargets.Description(value: homeDescription(at: coordinate), hint: nil)
                } onTap: { _ in }
            }
        }
        .battleAnchor(isMiniature ? nil : .homeBoard)
        .landingPunch(on: ledger.landings)
        // On top of the host's hit-taken shake (7; 4 on the mini map), so a sunk totals about 10.
        .shakes(on: ledger.sunkLandings, amplitude: 3, amplitudeY: 2, roll: 0.5)
        .animation(Motion.Curve.state.policy(policy), value: seaState)
        .animation(Motion.Curve.state.policy(policy), value: wash)
        .animation(Motion.Curve.state.policy(policy), value: isUnderFire)
        .onChange(of: finaleStampID) { _, id in
            if id != nil {
                finaleSweeps += 1
            }
        }
    }

    /// The mark to draw at `coordinate`: none until the enemy's shell has landed there, and a hit
    /// rather than a sunk while another cell of the same hull is still awaiting its landing.
    private func displayedMark(at coordinate: Coordinate, hidden: Set<Coordinate>) -> CellMark? {
        guard !hidden.contains(coordinate), let mark = perspective.homeMark(at: coordinate) else { return nil }
        if mark == .sunk, let ship = perspective.myShip(at: coordinate), ship.cells.contains(where: { hidden.contains($0) }) {
            return .hit
        }
        return mark
    }

    private func homeDescription(at coordinate: Coordinate) -> String {
        let ship = perspective.myShip(at: coordinate)
        switch (perspective.homeMark(at: coordinate), ship) {
        case (.miss, _): return "Enemy miss"
        case let (.hit, ship?): return "Your \(ship.kind.displayName), hit"
        case let (.sunk, ship?): return "Your \(ship.kind.displayName), sunk"
        case let (nil, ship?): return "Your \(ship.kind.displayName)"
        default: return "Open water"
        }
    }
}

// MARK: - The ships

/// Every ship on a board, placed in its berth and moved by the battle: the sail-in's slide and the
/// swell at anchor (offsets), the damage list, the sinking's list (rotations about the stern), and
/// the surfacing, sinking, wreck and darkening the ship's own art draws. One timeline for them all,
/// at the effects rate while a sinking, the sail-in or the finale's fleet plays, at 15 frames a second
/// for the swell on full-size home boards, and paused otherwise. Everything is a function of the
/// controller's dates through the board's clock, so slow motion stretches a sinking and a recreated
/// board resumes mid-way; the still tier shows end states and crossfades a sunk hull to its wreck.
private struct ShipsLayer: View {
    let geometry: BoardGeometry
    let board: BoardSide
    let controller: BattleController
    let ships: [ShipPlacement]
    let damage: [ShipPlacement: ShipDamage]
    let isMiniature: Bool
    /// The opening, for the sail-in (the home board).
    let opening: BattleController.Opening?
    /// The host's sail-in progress, when it drives it instead.
    let arrival: Double?
    let finale: Finale?
    /// The ships the finale takes in turn: surfacing on the target board, darkening on the home board.
    let fateShips: [ShipPlacement]
    @Environment(\.motionPolicy) private var policy
    @State private var isFinaleLive = false

    /// The sinking's beats, in seconds from the landing.
    private static let surfaceStart: TimeInterval = 0.12
    private static let surfaceEnd: TimeInterval = 0.6
    private static let listLength: TimeInterval = 1.2
    private static let sinkLength: TimeInterval = 1.6
    private static let wreckStart: TimeInterval = 1.6
    private static let wreckLength: TimeInterval = 0.6
    /// The finale's fleet: each ship surfaces or darkens over this long.
    private static let fateLength: TimeInterval = 0.5
    /// Degrees of list: per hit, the cap, a sinking hull, a doomed wreck.
    private static let listPerHit = 2.5
    private static let listCap = 5.0
    private static let sinkingList = 7.0
    private static let fateList = 4.0
    /// The swell's frame interval on full-size home boards.
    private static let swellInterval: TimeInterval = 1 / 15

    var body: some View {
        let sinkings = controller.sinkings.filter { $0.board == board }
        let clock = board == .target ? controller.targetClock : controller.homeClock
        let holdsStill = policy.holdsStill
        let isSailing = opening != nil && arrival == nil
        let isAnimating = (!sinkings.isEmpty || isSailing || isFinaleLive) && !holdsStill
        let bobs = !isMiniature && board == .home && policy.sceneryInterval != nil && !holdsStill
        let interval = isAnimating ? policy.effectsInterval : max(policy.sceneryInterval ?? Self.swellInterval, Self.swellInterval)
        let paused = !isAnimating && !bobs
        TimelineView(.animation(minimumInterval: interval, paused: paused)) { timeline in
            let effectTime = clock.time(at: timeline.date)
            let seconds = Motion.seconds(timeline.date)
            // Shares the board's coordinates: the ships inside are placed with `position`.
            ZStack(alignment: .topLeading) {
                ForEach(Array(ships.enumerated()), id: \.element) { index, ship in
                    shipView(ship, index: index, effectTime: effectTime, seconds: seconds, sinkings: sinkings, clock: clock, bobs: bobs, holdsStill: holdsStill)
                }
            }
        }
        .motionBudgeted(isLive: !paused)
        .task(id: finale?.start) {
            // The finale's fleet plays out over a few seconds after the final blow.
            guard let finale, !fateShips.isEmpty, !policy.holdsStill else {
                isFinaleLive = false
                return
            }
            isFinaleLive = true
            let remaining = finale.start.addingTimeInterval(EffectsLayer.finaleLength + EffectsLayer.slack).timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            isFinaleLive = false
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func shipView(
        _ ship: ShipPlacement, index: Int, effectTime: TimeInterval, seconds: Double,
        sinkings: [Sinking], clock: FXClock, bobs: Bool, holdsStill: Bool
    ) -> some View {
        let cell = geometry.cell
        let rect = geometry.rect(for: ship).insetBy(dx: cell * 0.1, dy: cell * 0.1)
        let state = damage[ship] ?? ShipDamage.none
        let isVertical = ship.orientation == .vertical
        let sinking = sinkings.first { $0.ship == ship }

        // The sinking: the reveal (enemy waters), the list, the waterline, the wreck coming in.
        var surfacing = 1.0
        var sink = 0.0
        var wreck = 0.0
        var sinkList = 0.0
        if let sinking, !holdsStill {
            let elapsed = effectTime - clock.time(at: sinking.start)
            if board == .target {
                surfacing = Motion.easeOut(Self.window(elapsed, from: Self.surfaceStart, to: Self.surfaceEnd))
            }
            sink = Self.window(elapsed, from: Timing.listStart, to: Timing.listStart + Self.sinkLength)
            wreck = Self.window(elapsed, from: Self.wreckStart, to: Self.wreckStart + Self.wreckLength)
            sinkList = Self.sinkingList * Easing.easeInOut(Self.window(elapsed, from: Timing.listStart, to: Timing.listStart + Self.listLength))
        }

        // The finale's fleet: never-found hulls surfacing in turn, or the wrecks darkening in turn.
        var fateDarkening = 0.0
        var fateList = 0.0
        var isAwaitingFate = false
        if let finale, let fate = fateShips.firstIndex(of: ship) {
            if holdsStill {
                fateDarkening = board == .home ? 1 : 0
            } else {
                let elapsed = effectTime - clock.time(at: finale.start)
                let stagger = board == .target ? Timing.Stagger.surfacing : Timing.Stagger.fleetFate
                let begin = Timing.fleetSurfaceStart + Double(min(fate, Timing.Stagger.maxItems)) * stagger
                let progress = Self.window(elapsed, from: begin, to: begin + Self.fateLength)
                if board == .target {
                    surfacing = Motion.easeOut(progress)
                    isAwaitingFate = elapsed < begin
                } else {
                    fateDarkening = progress
                    fateList = Self.fateList * Motion.easeOut(progress)
                }
            }
        }

        // The damage list: 2.5° a hit, alternating sides, capped; nothing once the hull is a wreck.
        let hits = state.hitCells.count
        let damageList = state.isSunk || hits == 0 ? 0 : min(Self.listCap, Self.listPerHit * Double(hits)) * (hits % 2 == 0 ? -1 : 1)

        // The sail-in and the swell.
        let sail = sailOffset(of: ship, index: index, effectTime: effectTime, clock: clock)
        let swell: (lift: CGFloat, roll: Double) = bobs && !state.isSunk && sinking == nil && opening == nil
            ? Self.swell(of: ship, index: index, at: seconds)
            : (0, 0)

        return ShipView(ship: ship, damage: state, surfacing: surfacing, sinkProgress: sink, wreckFade: wreck, darkening: fateDarkening)
            .transition(.opacity)
            .id(holdsStill ? state.isSunk : false)
            .frame(width: rect.width, height: rect.height)
            .rotationEffect(.degrees(damageList + sinkList + fateList + swell.roll), anchor: ShipArt.sternAnchor(isVertical: isVertical))
            .animation(Motion.Curve.settle.policy(policy), value: damageList)
            .offset(x: sail.width, y: sail.height + swell.lift)
            .animation(Motion.Curve.wipe.policy(policy), value: opening == nil)
            .opacity(isAwaitingFate ? 0 : 1)
            .position(x: rect.midX, y: rect.midY)
            .animation(Motion.Curve.reduced, value: holdsStill ? state.isSunk : false)
    }

    /// Where the ship is relative to its berth during the sail-in: from the host's `arrival`, or from
    /// the opening's own clock; home once the opening is over.
    private func sailOffset(of ship: ShipPlacement, index: Int, effectTime: TimeInterval, clock: FXClock) -> CGSize {
        if policy.collapsesSequences || policy.holdsStill {
            return .zero
        }
        if let arrival {
            let progress = Motion.easeOut(min(1, max(0, (arrival * SailIn.length - SailIn.start(of: index)) / SailIn.shipLength)))
            return SailIn.offset(of: ship, geometry: geometry, progress: progress)
        }
        switch opening {
        case .matchFound?:
            return SailIn.offset(of: ship, geometry: geometry, progress: 0)
        case let .playing(start)?:
            return SailIn.offset(of: ship, geometry: geometry, progress: SailIn.progress(index: index, since: clock.time(at: start), at: effectTime))
        case nil:
            return .zero
        }
    }

    /// `value` as 0…1 across `from`…`to`.
    private static func window(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        return min(max((value - from) / (to - from), 0), 1)
    }

    /// A ship's rise and roll on the swell at `seconds`: about 1 pt and ±0.6° on its own 4–6 s period,
    /// phased by where it lies so the fleet never moves in unison.
    private static func swell(of ship: ShipPlacement, index: Int, at seconds: Double) -> (lift: CGFloat, roll: Double) {
        let period = 4 + Double((index * 7 + ship.length) % 5) * 0.5
        let phase = Double(ship.origin.row * 3 + ship.origin.column) * 0.7
        let angle = 2 * Double.pi * seconds / period + phase
        return (CGFloat(sin(angle)), 0.6 * sin(angle + 1.1))
    }
}

// MARK: - The water's memory and the landings

/// What a board remembers of the shells that landed on it while it was on screen: a count of
/// landings (the punch), of sunk landings (the extra shake), of shells fired (the cloud pass), and
/// the rings and stains the water draws for them (BAT-10). Primed with whatever has already landed
/// when the board appears, so a board opened mid-battle doesn't replay it.
private struct LandingLedger: Equatable {
    private var seen: Set<UUID> = []
    private var seenShells: Set<UUID> = []
    private var isPrimed = false
    private(set) var landings = 0
    private(set) var sunkLandings = 0
    private(set) var firings = 0
    private(set) var impacts: [WaterImpact] = []
    private(set) var stains: [WaterStain] = []

    /// How long an oil stain holds on the water.
    static let oilLife: TimeInterval = 20

    mutating func noteLandings(_ current: [Impact], geometry: BoardGeometry) {
        let now = Date().timeIntervalSinceReferenceDate
        if isPrimed {
            for impact in current where !seen.contains(impact.id) {
                landings += 1
                if impact.isSunk {
                    sunkLandings += 1
                }
                let point = geometry.center(of: impact.coordinate)
                let start = impact.start.timeIntervalSinceReferenceDate
                impacts.append(WaterImpact(x: point.x, y: point.y, start: start, kind: impact.isHit ? .hit : .splash))
                stains.append(WaterStain(x: point.x, y: point.y, start: start, strength: impact.isHit ? 1 : -1))
            }
        }
        isPrimed = true
        seen = Set(current.map(\.id))
        impacts.removeAll { now - $0.start > WaterImpact.life }
        stains.removeAll { now - $0.start > ($0.isFoam ? WaterStain.foamLife : Self.oilLife) }
    }

    mutating func noteShells(_ current: [UUID]) {
        if isPrimed {
            firings += current.filter { !seenShells.contains($0) }.count
        }
        seenShells = Set(current)
    }
}

/// A cloud's shadow sweeping across the enemy waters as the player's shot goes, 0.8 s, each time
/// `trigger` changes (BAT-9). The full tier only.
private struct CloudPass: View {
    let geometry: BoardGeometry
    let trigger: Int
    @Environment(\.motionPolicy) private var policy

    static let length: TimeInterval = 0.8

    var body: some View {
        let grid = geometry.gridRect
        let width = grid.width * 0.6
        if policy.tier == .full {
            OneShot(trigger: trigger, duration: Self.length, curve: { Easing.easeInOut($0) }) { progress in
                Rectangle()
                    .fill(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.22), .black.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width, height: grid.height)
                    .position(x: grid.minX - width / 2 + progress * (grid.width + width), y: grid.midY)
                    .opacity(progress < 1 ? 1 : 0)
            }
            .clipShape(
                RoundedRectangle(cornerRadius: min(14, geometry.cell * 0.35), style: .continuous)
                    .size(width: grid.width, height: grid.height)
                    .offset(x: grid.minX, y: grid.minY)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Invisible, accessible tap targets, one per cell, so VoiceOver can explore the board square by square.
struct CellTargets: View {
    struct Description {
        let value: String
        let hint: String?
    }

    let geometry: BoardGeometry
    let rules: Rules
    let describe: @MainActor (Coordinate) -> Description
    let onTap: @MainActor (Coordinate) -> Void

    var body: some View {
        ForEach(rules.allCoordinates, id: \.self) { coordinate in
            let rect = geometry.rect(for: coordinate)
            let description = describe(coordinate)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .onTapGesture { onTap(coordinate) }
                .hoverEffect(.highlight)
                .accessibilityElement()
                .accessibilityLabel(coordinate.notation)
                .accessibilityValue(description.value)
                .accessibilityHint(description.hint ?? "")
                .accessibilityAddTraits(description.hint == nil ? [] : .isButton)
                .accessibilityAction { onTap(coordinate) }
        }
    }
}

private extension BattleController {
    /// The cells on `board` whose result is still a secret at `now`: a shell for them is in the air
    /// (held at the apex, or landing later), or the enemy's telegraphed shell hasn't landed yet. The
    /// boards draw no mark there until it has.
    func cellsAwaitingLanding(on board: BoardSide, at now: Date) -> Set<Coordinate> {
        var cells = Set<Coordinate>()
        for shell in shells where shell.board == board && shell.outcome != .misfire {
            if let lands = shell.lands, lands <= now {
                continue
            }
            cells.insert(shell.coordinate)
        }
        if board == .home, let telegraph, telegraph.lands > now {
            cells.insert(telegraph.coordinate)
        }
        return cells
    }
}
