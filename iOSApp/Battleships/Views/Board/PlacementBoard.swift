import BattleshipCore
import SwiftUI

/// Lets the player drag ships into position and tap them to turn them (DEP-1), rides them at anchor
/// on the swell (BAT-11), and plays the cast-off the screen above drives (DEP-2).
///
/// Each ship is two layers. The art is `ShipView` always laid out horizontally and, for a vertical
/// ship, turned as one piece by `rotationEffect` about its origin cell; it lifts, tilts, squashes,
/// shudders and sails, and takes no touches. The hit layer is a clear rectangle over the ship's real
/// cells in its current orientation, carrying the gestures and the accessibility element; it never
/// animates, so hit testing and the VoiceOver frame are exact the moment a ship turns.
struct PlacementBoard: View {
    let model: FleetPlacementModel
    let feedback: any FeedbackPlayer
    /// Set while a ship is being dragged, so the screen around the board can stop scrolling.
    @Binding var isDragging: Bool
    /// Bump it to shuffle the fleet: the ships fly to a new layout one after another.
    var shuffle = 0
    /// Where the cast-off has got to; `.idle` until the fleet is confirmed.
    var deploy: DeployPhase = .idle
    /// Bump it to replay the fleet's arrival.
    var arrival = 0
    /// Turns ships and shuffles from outside the gestures (the filmstrips).
    var director: PlacementDirector? = nil

    private struct Drag: Equatable {
        let index: Int
        var translation: CGSize
        /// Where the ship would land if dropped now.
        var candidate: ShipPlacement
        /// The hull's yaw toward the direction of travel, in degrees, low-passed frame to frame.
        var tilt: Double
    }

    /// What last moved the ships, set in the same update as the model change, so each ship's
    /// position animates on the right curve and delay.
    private enum Motive: Equatable {
        case none
        case drop(Int)
        case turn(Int, slides: Bool)
        case nudge(Int)
        case shuffle(Int)
    }

    /// Resets by itself when the system cancels a drag (Control Center, a call), which `onEnded`
    /// never hears about. The reset drops the ship on `Motion.Curve.drop`, the curve its berth moves
    /// on, so the lifted ship and its new berth meet on one path.
    @GestureState(resetTransaction: Transaction(animation: Motion.Curve.drop))
    private var drag: Drag? = nil
    @State private var motive = Motive.none
    @State private var shuffles = 0
    /// Rings on the water where ships have just landed (BAT-10).
    @State private var impacts: [WaterImpact] = []
    @State private var plunks: [Plunk] = []
    /// Per ship: bumped on each landing (the squash) and each refusal (the shudder).
    @State private var squashes: [Int: Int] = [:]
    @State private var shudders: [Int: Int] = [:]
    /// Where the last refused ship would have gone, flashed red.
    @State private var invalidGhost: ShipPlacement?
    @State private var refusals = 0
    /// Where the last turned ship landed, lit for a moment.
    @State private var turnGlow: ShipPlacement?
    @State private var turns = 0
    @Environment(\.motionPolicy) private var policy

    /// Drags are measured in the board's space, which stays put while the dragged ship moves.
    private static var boardSpace: NamedCoordinateSpace { .named("PlacementBoard") }

    var body: some View {
        BoardView(rules: model.rules, accent: deploy.isLocked ? Theme.victory : Theme.reticle, impacts: impacts) { geometry in
            if let drag, model.ships.indices.contains(drag.index) {
                HoverShadow(rect: geometry.rect(for: model.ships[drag.index]), translation: drag.translation)
                landingGhost(drag, geometry: geometry)
            }
            turnGlowView(geometry)
            InvalidGhostFlash(ghost: invalidGhost, geometry: geometry, trigger: refusals)
            ships(geometry)
            ForEach(model.ships.indices, id: \.self) { index in
                LockBrackets(rect: geometry.rect(for: model.ships[index]), isLocked: deploy == .locking, index: index)
            }
            PlacementEffectsLayer(plunks: plunks, cell: geometry.cell)
                .task(id: arrival) { await landArrivingShips(geometry) }
                .task(id: shuffles) { await landShuffledShips(geometry) }
            BezelSweep(geometry: geometry, isLocked: deploy.isLocked)
            ForEach(model.ships.indices, id: \.self) { index in
                hitLayer(at: index, geometry: geometry)
            }
        }
        .coordinateSpace(Self.boardSpace)
        .onChange(of: drag) { old, new in
            isDragging = new != nil
            guard let new else { return }
            if old == nil {
                model.selectedIndex = new.index
                feedback.play(.lift)
            } else if old?.candidate != new.candidate {
                feedback.play(.select)
            }
        }
        .onChange(of: shuffle) { shuffleFleet() }
        .onChange(of: director?.shuffles) { shuffleFleet() }
        .onChange(of: director?.turns) {
            if let director {
                turn(director.shipIndex)
            }
        }
        .task(id: deploy) { await tickLocks() }
    }

    // MARK: Layers

    /// The art layers, riding the swell on one scenery clock that stops during a drag and the cast-off.
    private func ships(_ geometry: BoardGeometry) -> some View {
        let bobs = drag == nil && deploy == .idle
        return LoopClock(loop: .scenery, isLive: bobs) { seconds in
            // Shares the board's coordinates: the art inside is placed with `position`.
            ZStack(alignment: .topLeading) {
                ForEach(model.ships.indices, id: \.self) { index in
                    let ship = model.ships[index]
                    let swell = Self.swell(of: ship, index: index, at: seconds)
                    let isDragged = drag?.index == index
                    PlacementShipArt(
                        ship: ship,
                        index: index,
                        geometry: geometry,
                        isSelected: model.selectedIndex == index,
                        translation: isDragged ? drag?.translation : nil,
                        tilt: isDragged ? (drag?.tilt ?? 0) : 0,
                        lift: swell.lift,
                        roll: swell.roll,
                        deploy: deploy,
                        arrival: arrival,
                        squashes: squashes[index, default: 0],
                        shudders: shudders[index, default: 0],
                        positionAnimation: positionAnimation(for: index),
                        rotationAnimation: Motion.Curve.rotate.policy(policy),
                        departureAnimation: departureAnimation(for: index)
                    )
                }
            }
        }
        // Departing ships slip under the water's edge rather than over the screen.
        .clipShape(Self.clip(geometry, toWater: deploy != .idle))
    }

    @ViewBuilder
    private func landingGhost(_ drag: Drag, geometry: BoardGeometry) -> some View {
        let fits = model.canPlace(drag.candidate, replacing: drag.index)
        let rect = geometry.rect(for: drag.candidate).insetBy(dx: 2, dy: 2)
        let tint = fits ? Theme.victory : Theme.hit
        RoundedRectangle(cornerRadius: geometry.cell * 0.3, style: .continuous)
            .fill(tint.opacity(0.28))
            .overlay(
                RoundedRectangle(cornerRadius: geometry.cell * 0.3, style: .continuous)
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            // The ghost snaps cell to cell.
            .animation(Motion.Curve.press.policy(policy), value: drag.candidate)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func turnGlowView(_ geometry: BoardGeometry) -> some View {
        // A landing glow is a flash: none under Dim Flashing Lights or with flashes off.
        if policy.allowsFlashes {
            OneShot(trigger: turns, duration: DeployBeat.turnGlow) { progress in
                if let turnGlow {
                    let rect = geometry.rect(for: turnGlow).insetBy(dx: 2, dy: 2)
                    RoundedRectangle(cornerRadius: geometry.cell * 0.3, style: .continuous)
                        .fill(Theme.reticle.opacity(0.3 * (1 - progress)))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The touch and VoiceOver layer over a ship's real cells. It carries no picture and never
    /// animates, so a turned ship is hit and read in its new place at once.
    @ViewBuilder
    private func hitLayer(at index: Int, geometry: BoardGeometry) -> some View {
        let ship = model.ships[index]
        let rect = geometry.rect(for: ship)
        Color.clear
            .contentShape(Rectangle())
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .transaction { $0.animation = nil }
            .onTapGesture { turn(index) }
            // Wins over the scroll view around the board, so dragging a ship up or down moves the ship.
            .highPriorityGesture(dragGesture(for: index, geometry: geometry))
            .accessibilityElement()
            .accessibilityLabel("\(ship.kind.displayName), \(Phrase.count(ship.length, "square"))")
            .accessibilityValue(Self.spokenPlacement(of: ship))
            .accessibilityHint(ship.length > 1 ? "Double-tap to turn. Swipe up or down for more actions." : "Swipe up or down for actions that move it.")
            .accessibilityAction { turn(index) }
            .accessibilityAction(named: "Move up") { nudge(index, rows: -1, geometry: geometry) }
            .accessibilityAction(named: "Move down") { nudge(index, rows: 1, geometry: geometry) }
            .accessibilityAction(named: "Move left") { nudge(index, columns: -1, geometry: geometry) }
            .accessibilityAction(named: "Move right") { nudge(index, columns: 1, geometry: geometry) }
            .accessibilityAction(named: "Shuffle fleet") { shuffleFleet() }
            // Nothing moves once the fleet is confirmed.
            .allowsHitTesting(deploy == .idle)
    }

    // MARK: Gestures and actions

    private func dragGesture(for index: Int, geometry: BoardGeometry) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: Self.boardSpace)
            .updating($drag) { value, state, _ in
                guard let landing = candidate(for: index, translation: value.translation, cell: geometry.cell) else { return }
                let target = Self.tilt(toward: value.velocity, along: landing.orientation)
                let previous = state?.tilt ?? 0
                state = Drag(index: index, translation: value.translation, candidate: landing, tilt: previous + (target - previous) * 0.3)
            }
            .onEnded { value in
                guard let landing = candidate(for: index, translation: value.translation, cell: geometry.cell) else { return }
                drop(index, at: landing, geometry: geometry)
            }
    }

    /// The ship moved by `translation`, snapped to whole cells.
    private func candidate(for index: Int, translation: CGSize, cell: CGFloat) -> ShipPlacement? {
        guard model.ships.indices.contains(index), cell > 0 else { return nil }
        let ship = model.ships[index]
        let columns = Int((translation.width / cell).rounded())
        let rows = Int((translation.height / cell).rounded())
        return ship.moved(to: ship.origin.offsetBy(rows: rows, columns: columns))
    }

    private func drop(_ index: Int, at landing: ShipPlacement, geometry: BoardGeometry) {
        guard model.ships.indices.contains(index), deploy == .idle else { return }
        if model.canPlace(landing, replacing: index) {
            motive = .drop(index)
            model.move(index, to: landing.origin)
            squashes[index, default: 0] += 1
            plunk(landing, geometry: geometry)
            feedback.play(.place)
        } else {
            refuse(index, ghost: landing)
        }
    }

    /// A tap turns a ship about its origin cell; a one-square boat looks the same either way round,
    /// so a tap just picks it out.
    private func turn(_ index: Int) {
        guard model.ships.indices.contains(index), deploy == .idle else { return }
        let ship = model.ships[index]
        model.selectedIndex = index
        guard ship.length > 1 else {
            feedback.play(.select)
            return
        }
        motive = .turn(index, slides: false)
        if model.rotate(index) {
            let turned = model.ships[index]
            motive = .turn(index, slides: turned.origin != ship.origin)
            turnGlow = turned
            turns += 1
            feedback.play(.rotate)
            if policy.isVoiceOverRunning {
                AccessibilityNotification.Announcement(Self.spokenPlacement(of: turned)).post()
            }
        } else {
            refuse(index, ghost: ship.rotated())
        }
    }

    /// Keyboard and VoiceOver users move a ship one cell at a time; the move keeps its spring and its plunk.
    private func nudge(_ index: Int, rows: Int = 0, columns: Int = 0, geometry: BoardGeometry) {
        guard model.ships.indices.contains(index), deploy == .idle else { return }
        let ship = model.ships[index]
        motive = .nudge(index)
        if model.nudge(index, rows: rows, columns: columns) {
            plunk(model.ships[index], geometry: geometry)
            feedback.play(.place)
        } else {
            refuse(index, ghost: ship.moved(to: ship.origin.offsetBy(rows: rows, columns: columns)))
        }
    }

    private func shuffleFleet() {
        guard deploy == .idle else { return }
        shuffles += 1
        motive = .shuffle(shuffles)
        model.shuffle()
        feedback.play(.shuffle, variation: FeedbackVariation(count: model.ships.count))
    }

    private func refuse(_ index: Int, ghost: ShipPlacement) {
        motive = .none
        shudders[index, default: 0] += 1
        invalidGhost = ghost
        refusals += 1
        feedback.play(.invalid)
    }

    /// A ring in the water and droplets off the hull where `ship` has just landed.
    private func plunk(_ ship: ShipPlacement, geometry: BoardGeometry) {
        let rect = geometry.rect(for: ship)
        let now = Date().timeIntervalSinceReferenceDate
        impacts.removeAll { now - $0.start > WaterImpact.life }
        impacts.append(WaterImpact(x: rect.midX, y: rect.midY, start: now, kind: .splash))
        plunks.removeAll { now - $0.start > $0.duration }
        plunks.append(Plunk(rect: rect, cell: geometry.cell, start: now))
    }

    // MARK: Beats

    /// Staggers play in the full and reduced tiers; collapsed sequences and held clocks land at once.
    private var staggers: Bool {
        !policy.collapsesSequences && !policy.holdsStill
    }

    /// The arrival's plunks: a ring and a tap, scaled by the ship's size, as each ship lands.
    private func landArrivingShips(_ geometry: BoardGeometry) async {
        let ships = model.ships
        guard staggers else {
            feedback.play(.place)
            return
        }
        let start = Date()
        for (index, ship) in ships.enumerated() {
            let landing = Double(min(index, Timing.Stagger.maxItems)) * DeployBeat.arrival + DeployBeat.arrivalLanding
            let wait = landing - Date().timeIntervalSince(start)
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            guard !Task.isCancelled else { return }
            plunk(ship, geometry: geometry)
            feedback.play(.place, variation: FeedbackVariation(intensity: Self.tapIntensity(of: ship)))
        }
    }

    /// Shuffled ships land one after another: a ring and a squash each.
    private func landShuffledShips(_ geometry: BoardGeometry) async {
        guard shuffles > 0 else { return }
        let ships = model.ships
        let start = Date()
        for (index, ship) in ships.enumerated() {
            let landing = staggers ? Double(min(index, Timing.Stagger.maxItems)) * Timing.Stagger.ship + DeployBeat.flight : 0
            let wait = landing - Date().timeIntervalSince(start)
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            guard !Task.isCancelled else { return }
            plunk(ship, geometry: geometry)
            squashes[index, default: 0] += 1
        }
    }

    /// A select tick as each lock bracket snaps on.
    private func tickLocks() async {
        guard deploy == .locking else { return }
        guard staggers else {
            feedback.play(.select)
            return
        }
        for index in model.ships.indices {
            if index > 0 {
                try? await Task.sleep(for: .seconds(DeployBeat.lock))
            }
            guard !Task.isCancelled else { return }
            feedback.play(.select)
        }
    }

    // MARK: Curves

    /// How the `index`th ship's berth moves for what last happened to the fleet.
    private func positionAnimation(for index: Int) -> Animation {
        switch motive {
        case .drop(let dropped) where dropped == index:
            // The gesture's reset curve, so the lifted ship and its berth meet on one path.
            return Motion.Curve.drop
        case .turn(let turned, let slides) where turned == index:
            // When the model slides a turned ship along to fit, the slide follows the turn.
            return slides && policy.tier == .full ? Motion.Curve.move.delay(DeployBeat.turnSlide) : Motion.Curve.move.policy(policy)
        case .nudge(let nudged) where nudged == index:
            // VoiceOver nudges keep their spring.
            return Motion.Curve.snap
        case .shuffle:
            let delay = staggers ? Double(min(index, Timing.Stagger.maxItems)) * Timing.Stagger.ship : 0
            return Motion.Curve.move.policy(policy).delay(delay)
        default:
            return Motion.Curve.move.policy(policy)
        }
    }

    /// How the `index`th ship casts off, or sails back.
    private func departureAnimation(for index: Int) -> Animation {
        switch deploy {
        case .departing:
            let delay = staggers ? Double(min(index, Timing.Stagger.maxItems)) * DeployBeat.castOff : 0
            return Motion.Curve.depart.policy(policy).delay(delay)
        case .returning:
            return Motion.Curve.sail.policy(policy)
        case .idle, .locking:
            return Motion.Curve.move.policy(policy)
        }
    }

    // MARK: Helpers

    /// A ship's rise and roll on the swell at `seconds`: about 1 pt and ±0.6° on its own 4–6 s period,
    /// phased by where it lies so the fleet never moves in unison. Nothing when the clock holds still.
    private static func swell(of ship: ShipPlacement, index: Int, at seconds: Double?) -> (lift: CGFloat, roll: Double) {
        guard let seconds else { return (0, 0) }
        let period = 4 + Double((index * 7 + ship.length) % 5) * 0.5
        let phase = Double(ship.origin.row * 3 + ship.origin.column) * 0.7
        let angle = 2 * Double.pi * seconds / period + phase
        return (CGFloat(sin(angle)), 0.6 * sin(angle + 1.1))
    }

    /// The yaw that turns a hull's bow toward the direction it is being dragged, up to 6°: from the
    /// drag velocity across the hull's axis, saturating at 600 points a second.
    private static func tilt(toward velocity: CGSize, along orientation: Orientation) -> Double {
        let across = orientation == .horizontal ? velocity.height : -velocity.width
        let unit = min(max(Double(across) / 600, -1), 1)
        return unit * 6
    }

    /// The water's rounded rect while ships cast off, and no clip at all otherwise.
    private static func clip(_ geometry: BoardGeometry, toWater: Bool) -> AnyShape {
        guard toWater else {
            return AnyShape(Rectangle().inset(by: -10_000))
        }
        let rect = geometry.gridRect
        return AnyShape(
            RoundedRectangle(cornerRadius: min(14, geometry.cell * 0.35), style: .continuous)
                .size(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        )
    }

    /// A light tap for a boat, a firmer one for a carrier.
    private static func tapIntensity(of ship: ShipPlacement) -> Double {
        min(1, 0.45 + 0.11 * Double(ship.length))
    }

    /// "Horizontal, from B3 to B7".
    private static func spokenPlacement(of ship: ShipPlacement) -> String {
        "\(ship.orientation == .horizontal ? "Horizontal" : "Vertical"), from \(ship.origin.notation) to \(ship.end.notation)"
    }
}

/// One ship's art: `ShipView` laid out horizontally along its cells and turned about its origin cell
/// when vertical, so a turn is a true rotation and the hull never morphs. In the still tier it is
/// drawn in its real orientation and a turn crossfades instead. It takes no touches.
private struct PlacementShipArt: View {
    let ship: ShipPlacement
    let index: Int
    let geometry: BoardGeometry
    let isSelected: Bool
    /// The drag's translation when this is the ship being dragged.
    let translation: CGSize?
    /// The hull's yaw toward the direction of travel, in degrees.
    let tilt: Double
    /// The swell's lift, in points, and roll, in degrees.
    let lift: CGFloat
    let roll: Double
    let deploy: DeployPhase
    let arrival: Int
    let squashes: Int
    let shudders: Int
    let positionAnimation: Animation
    let rotationAnimation: Animation
    let departureAnimation: Animation
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let cell = geometry.cell
        let inset = cell * 0.08
        let moves = policy.tier != .still
        let isVertical = ship.orientation == .vertical
        let isLifted = translation != nil
        let isDeparting = deploy.isDeparting
        let rect = geometry.rect(for: ship).insetBy(dx: inset, dy: inset)
        let origin = geometry.center(of: ship.origin)
        let length = cell * CGFloat(ship.length) - inset * 2
        let beam = cell - inset * 2
        // Horizontal art centred along its cells, with its origin cell at `origin`; or, in the still
        // tier, the art of the real orientation in its real rect.
        let size = moves ? CGSize(width: length, height: beam) : rect.size
        let center = moves
            ? CGPoint(x: origin.x + cell * CGFloat(ship.length - 1) / 2, y: origin.y)
            : CGPoint(x: rect.midX, y: rect.midY)
        let pivot = UnitPoint(x: length > 0 ? (cell / 2 - inset) / length : 0.5, y: 0.5)
        let art = moves ? ShipPlacement(kind: ship.kind, origin: ship.origin, orientation: .horizontal) : ship
        let artID: Orientation = moves ? .horizontal : ship.orientation
        let castOff: CGSize = isDeparting && moves ? Self.castOffOffset(of: ship, origin: origin, geometry: geometry) : .zero
        let wakeOpacity: Double = isDeparting && moves ? 0.4 : 0
        let scale: CGFloat = isLifted && moves ? 1.08 : (isDeparting && moves ? 1.04 : 1)
        let yaw: Double = roll + (moves ? tilt : 0)
        let turn: Double = moves && isVertical ? 90 : 0
        let shadowOpacity: Double = isLifted ? 0.45 : 0
        let shadowRadius: CGFloat = isLifted ? 14 : 3
        let shadowDrop: CGFloat = isLifted ? 10 : 2
        let artOpacity: Double = isDeparting && !moves ? 0 : 1

        ZStack {
            ShipView(ship: art, isHighlighted: isLifted || isSelected)
                .id(artID)
                .transition(.opacity)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .leading) {
            // The wake trails from the stern, the left end of the horizontal art, and turns with it.
            WakeStreak(length: cell * 1.6, beam: beam)
                .offset(x: -cell * 1.6)
                .opacity(wakeOpacity)
        }
        .dropsAnchor(index: index, trigger: arrival)
        .dropSquash(on: squashes)
        .shipShudder(on: shudders)
        .scaleEffect(scale)
        .rotationEffect(.degrees(yaw))
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowDrop)
        .animation(Motion.Curve.lift.policy(policy), value: isLifted)
        .rotationEffect(.degrees(turn), anchor: pivot)
        .animation(rotationAnimation, value: ship.orientation)
        .offset(translation ?? .zero)
        .offset(x: castOff.width, y: castOff.height + lift)
        .opacity(artOpacity)
        .animation(departureAnimation, value: deploy)
        .position(center)
        .animation(positionAnimation, value: ship)
        .zIndex(isLifted ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// How far a ship slides to clear the board bow-first: right for a horizontal ship, down for a vertical one.
    private static func castOffOffset(of ship: ShipPlacement, origin: CGPoint, geometry: BoardGeometry) -> CGSize {
        let grid = geometry.gridRect
        let cell = geometry.cell
        return ship.orientation == .horizontal
            ? CGSize(width: grid.maxX - origin.x + cell, height: 0)
            : CGSize(width: 0, height: grid.maxY - origin.y + cell)
    }
}
