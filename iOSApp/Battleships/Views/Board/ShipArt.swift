import BattleshipCore
import SwiftUI

/// What has happened to a ship, for its art: the cells along it that have been hit (0 is the origin
/// cell), and whether it has gone down (the static wreck).
struct ShipDamage: Equatable, Sendable {
    var hitCells: Set<Int> = []
    var isSunk = false

    static let none = ShipDamage()

    /// The damage of `ship` from a board's marks: `mark(cell)` for each of its cells, in order.
    static func of(_ ship: ShipPlacement, isSunk: Bool, mark: (Coordinate) -> CellMark?) -> ShipDamage {
        var hits = Set<Int>()
        for (index, cell) in ship.cells.enumerated() {
            switch mark(cell) {
            case .hit, .sunk: hits.insert(index)
            case .miss, nil: break
            }
        }
        return ShipDamage(hitCells: hits, isSunk: isSunk)
    }
}

/// A ship seen from above, drawn to fill its frame: hull, deck, guns and superstructure in the
/// style of its class, with craters where it has been hit. Sunk ships are drawn as charred wrecks.
/// `surfacing` (0…1) is the hull rising into view from the stern (the target board's reveal, the
/// finale's fleet); `sinkProgress` (0…1) is the hull going under stern first while it darkens, and
/// `wreckFade` (0…1) the wreck art coming in beneath it; `darkening` (0…1) dims a wreck further (the
/// finale's fleet fate). The listing and the bob are transforms the board applies outside.
struct ShipView: View {
    let ship: ShipPlacement
    var isSunk = false
    var isHighlighted = false
    var damage: ShipDamage? = nil
    var surfacing: Double = 1
    var sinkProgress: Double = 0
    var wreckFade: Double = 0
    var darkening: Double = 0

    var body: some View {
        let kind = ship.kind
        let isVertical = ship.orientation == .vertical
        let state: ShipDamage = {
            var state = damage ?? ShipDamage.none
            state.isSunk = state.isSunk || isSunk
            return state
        }()
        let surfacing = min(1, max(0, self.surfacing))
        let sink = min(1, max(0, sinkProgress))
        let wreck = min(1, max(0, wreckFade))
        let darkening = min(1, max(0, self.darkening))
        let isWreck = state.isSunk && sink <= 0 && wreck <= 0
        Canvas { context, size in
            ShipArt.draw(kind, damage: state, isVertical: isVertical, surfacing: surfacing, sink: sink, wreck: wreck, darkening: darkening, in: context, size: size)
        }
        .overlay {
            if isHighlighted {
                HullShape(kind: kind, isVertical: isVertical)
                    .stroke(Theme.reticle, lineWidth: 2)
                    .glow(Theme.reticle, radius: 6)
            }
        }
        .shadow(color: isWreck ? Theme.hit.opacity(0.4) : .black.opacity(0.5 * surfacing), radius: isWreck ? 5 : 3, y: isWreck ? 0 : 2)
    }
}

/// The outline of a ship's hull, bow to the right (or to the bottom when upright).
struct HullShape: Shape {
    var kind: ShipKind
    var isVertical = false

    func path(in rect: CGRect) -> Path {
        let length = isVertical ? rect.height : rect.width
        let beam = isVertical ? rect.width : rect.height
        var hull = ShipArt.hull(kind, length: length, beam: beam)
        if isVertical {
            // (x, y) → (beam − y, x): the stern ends up at the top, the bow at the bottom.
            hull = hull.applying(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: beam, ty: 0))
        }
        return hull.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// A warship in profile, for scenery: the lobby, the welcome screen and the end of a lost battle.
struct WarshipProfile: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        func block(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(origin: point(x, y), size: CGSize(width: width * rect.width, height: height * rect.height))
        }

        var path = Path()
        // Hull: a sheer line rising to a flared bow, down to the keel and back to the stern.
        path.move(to: point(0.03, 0.60))
        path.addLine(to: point(0.78, 0.57))
        path.addLine(to: point(0.99, 0.49))
        path.addLine(to: point(0.93, 0.80))
        path.addLine(to: point(0.90, 0.95))
        path.addLine(to: point(0.13, 0.95))
        path.addLine(to: point(0.05, 0.80))
        path.closeSubpath()

        // Guns, superstructure, funnel and mast.
        path.addRect(block(0.15, 0.48, 0.11, 0.13))
        path.addRect(block(0.05, 0.505, 0.11, 0.03))
        path.addRect(block(0.29, 0.40, 0.11, 0.21))
        path.move(to: point(0.42, 0.60))
        path.addLine(to: point(0.435, 0.27))
        path.addLine(to: point(0.505, 0.27))
        path.addLine(to: point(0.515, 0.60))
        path.closeSubpath()
        path.addRect(block(0.53, 0.32, 0.12, 0.29))
        path.addRect(block(0.55, 0.21, 0.08, 0.12))
        path.addRect(block(0.585, 0.03, 0.012, 0.19))
        path.addRect(block(0.555, 0.09, 0.07, 0.014))
        path.addRect(block(0.67, 0.47, 0.09, 0.12))
        path.addRect(block(0.75, 0.49, 0.12, 0.028))
        path.addRect(block(0.78, 0.515, 0.07, 0.07))
        path.addRect(block(0.84, 0.53, 0.10, 0.024))
        return path
    }
}

/// Draws ships for ``ShipView``. Everything is drawn lying horizontally, stern at the left and bow to
/// the right, then turned upright for vertical ships (stern at the top). Shading runs across the
/// beam, so it reads the same either way.
enum ShipArt {
    /// How much of the available beam each class uses: carriers are broad, patrol boats slight.
    static func beamFraction(_ kind: ShipKind) -> CGFloat {
        switch kind {
        case .carrier: 1
        case .battleship: 0.9
        case .cruiser: 0.82
        case .submarine: 0.68
        case .destroyer: 0.72
        case .patrolBoat: 0.62
        }
    }

    /// Where a ship pivots when it lists: its stern, the left end of the horizontal art or the top of
    /// the vertical art.
    static func sternAnchor(isVertical: Bool) -> UnitPoint {
        isVertical ? UnitPoint(x: 0.5, y: 0) : UnitPoint(x: 0, y: 0.5)
    }

    /// The hull outline in a `length` × `beam` box, centred across the beam.
    static func hull(_ kind: ShipKind, length: CGFloat, beam frameBeam: CGFloat) -> Path {
        let beam = frameBeam * beamFraction(kind)
        let top = (frameBeam - beam) / 2
        var path = Path()
        switch kind {
        case .submarine:
            let radius = min(beam / 2, length / 2)
            path.addRoundedRect(
                in: CGRect(x: 0, y: top, width: length, height: beam),
                cornerSize: CGSize(width: min(beam * 1.3, length / 2), height: radius)
            )
        case .carrier:
            let bow = min(beam * 0.75, length * 0.2)
            let chamfer = beam * 0.16
            path.move(to: CGPoint(x: chamfer, y: top))
            path.addLine(to: CGPoint(x: length - bow, y: top))
            path.addQuadCurve(to: CGPoint(x: length, y: top + beam * 0.5), control: CGPoint(x: length - bow * 0.1, y: top + beam * 0.06))
            path.addQuadCurve(to: CGPoint(x: length - bow, y: top + beam), control: CGPoint(x: length - bow * 0.1, y: top + beam * 0.94))
            path.addLine(to: CGPoint(x: chamfer, y: top + beam))
            path.addLine(to: CGPoint(x: 0, y: top + beam - chamfer))
            path.addLine(to: CGPoint(x: 0, y: top + chamfer))
            path.closeSubpath()
        default:
            let bow = min(beam * 1.25, length * 0.42)
            let stern = min(beam * 0.32, length * 0.18)
            path.move(to: CGPoint(x: stern, y: top))
            path.addLine(to: CGPoint(x: length - bow, y: top))
            path.addCurve(
                to: CGPoint(x: length, y: top + beam / 2),
                control1: CGPoint(x: length - bow * 0.45, y: top),
                control2: CGPoint(x: length - bow * 0.06, y: top + beam * 0.3)
            )
            path.addCurve(
                to: CGPoint(x: length - bow, y: top + beam),
                control1: CGPoint(x: length - bow * 0.06, y: top + beam * 0.7),
                control2: CGPoint(x: length - bow * 0.45, y: top + beam)
            )
            path.addLine(to: CGPoint(x: stern, y: top + beam))
            path.addQuadCurve(to: CGPoint(x: 0, y: top + beam * 0.62), control: CGPoint(x: 0, y: top + beam))
            path.addLine(to: CGPoint(x: 0, y: top + beam * 0.38))
            path.addQuadCurve(to: CGPoint(x: stern, y: top), control: CGPoint(x: 0, y: top))
            path.closeSubpath()
        }
        return path
    }

    /// `path` shrunk towards `center`.
    static func scaled(_ path: Path, x scaleX: CGFloat, y scaleY: CGFloat, around center: CGPoint) -> Path {
        path.applying(
            CGAffineTransform(translationX: center.x, y: center.y)
                .scaledBy(x: scaleX, y: scaleY)
                .translatedBy(x: -center.x, y: -center.y)
        )
    }

    /// The ship afloat or as a wreck, as before the damage and sinking were drawn.
    @MainActor
    static func draw(_ kind: ShipKind, isSunk: Bool, isVertical: Bool, in context: GraphicsContext, size: CGSize) {
        draw(kind, damage: ShipDamage(isSunk: isSunk), isVertical: isVertical, surfacing: 1, sink: 0, wreck: 0, darkening: 0, in: context, size: size)
    }

    /// The whole picture of a ship: the wreck (a sunk ship, or the wreck fading in by `wreck` during a
    /// sinking), the live hull above it (clipped by the waterline advancing from the stern by `sink`
    /// and darkening as it goes; veiled in sea colour beyond `surfacing` of its length with a cyan
    /// outline fading as it fills in), craters on the cells in `damage.hitCells`, and `darkening`.
    @MainActor
    static func draw(
        _ kind: ShipKind,
        damage: ShipDamage,
        isVertical: Bool,
        surfacing: Double,
        sink: Double,
        wreck: Double,
        darkening: Double,
        in context: GraphicsContext,
        size: CGSize
    ) {
        var base = context
        if isVertical {
            base.translateBy(x: size.width, y: 0)
            base.rotate(by: .degrees(90))
        }
        let length = isVertical ? size.height : size.width
        let frameBeam = isVertical ? size.width : size.height
        guard length > 2, frameBeam > 2 else { return }

        let beam = frameBeam * beamFraction(kind)
        let box = CGRect(x: 0, y: (frameBeam - beam) / 2, width: length, height: beam)
        let hullPath = hull(kind, length: length, beam: frameBeam)
        let isStaticWreck = damage.isSunk && sink <= 0 && wreck <= 0

        // The wreck, beneath: whole for a sunk ship, fading in under a sinking one.
        let wreckOpacity = isStaticWreck ? 1 : wreck
        if wreckOpacity > 0 {
            var layer = base
            layer.opacity = wreckOpacity
            if darkening > 0 {
                layer.addFilter(.brightness(-0.3 * darkening))
                layer.addFilter(.saturation(1 - 0.5 * darkening))
            }
            drawHull(kind, isWreck: true, damage: damage, hullPath: hullPath, box: box, in: layer)
            drawWreckage(hullPath, box: box, in: layer)
        }

        // The live hull: afloat, surfacing, or going under stern first.
        guard !isStaticWreck, sink < 1 else { return }
        var live = base
        if sink > 0 {
            live.clip(to: aboveWater(sink: sink, length: length, beam: frameBeam))
            live.addFilter(.brightness(-0.35 * sink))
            live.addFilter(.saturation(1 - 0.4 * sink))
        }
        if darkening > 0 {
            live.addFilter(.brightness(-0.3 * darkening))
            live.addFilter(.saturation(1 - 0.5 * darkening))
        }
        drawHull(kind, isWreck: false, damage: damage, hullPath: hullPath, box: box, in: live)

        if surfacing < 1 {
            // The sea still covers the hull beyond `surfacing` of its length from the stern, and the
            // cyan outline of a contact shows where it will be.
            var veil = live
            veil.clip(to: hullPath)
            veil.fill(underWater(surfacing: surfacing, length: length, beam: frameBeam), with: .color(Theme.seaTop.opacity(0.92)))
            live.stroke(hullPath, with: .color(Theme.reticle.opacity(0.9 * (1 - surfacing))), lineWidth: max(1, beam * 0.06))
        }
    }

    // MARK: The hull

    /// Hull, deck, the class's fittings, the outline and the craters, into `context`.
    @MainActor
    private static func drawHull(_ kind: ShipKind, isWreck: Bool, damage: ShipDamage, hullPath: Path, box: CGRect, in context: GraphicsContext) {
        let length = box.width
        let beam = box.height
        var art = context
        if isWreck {
            art.addFilter(.grayscale(0.85))
            art.addFilter(.colorMultiply(Color(red: 0.86, green: 0.52, blue: 0.44)))
            art.addFilter(.brightness(-0.06))
        }

        // Hull and deck, lit along the centre line.
        let isSubmarine = kind == .submarine
        let hullLight = isSubmarine ? Color(red: 0.36, green: 0.42, blue: 0.50) : Theme.hull
        let hullDark = isSubmarine ? Theme.submarine.opacity(0.95) : Theme.hullShadow
        art.fill(hullPath, with: acrossBeam([hullDark, hullLight, hullLight, hullDark], box: box))

        let rim = max(0.8, beam * 0.09)
        let deck = scaled(
            hullPath,
            x: (length - rim * 2) / length,
            y: (beam - rim * 2) / beam,
            around: CGPoint(x: box.midX, y: box.midY)
        )
        switch kind {
        case .carrier:
            art.fill(deck, with: acrossBeam([Theme.flightDeck.opacity(0.9), Theme.flightDeck, Theme.flightDeck.opacity(0.9)], box: box))
            drawCarrierDeck(in: &art, box: box)
        case .submarine:
            drawSubmarine(in: &art, box: box)
        default:
            art.fill(deck, with: acrossBeam([Theme.hullShadow, Theme.deck, Theme.deck, Theme.hullShadow], box: box))
            drawGunsAndBridge(kind, in: &art, box: box)
        }
        art.stroke(hullPath, with: .color(.black.opacity(0.4)), lineWidth: max(0.5, beam * 0.03))

        if !damage.hitCells.isEmpty {
            drawCraters(damage.hitCells, kind: kind, hullPath: hullPath, box: box, in: context)
        }
    }

    /// The region of the hull still above the water: everything from the waterline to the bow, the
    /// waterline a sine advancing from the stern (x = 0) to the bow (x = length) as `sink` runs 0…1.
    private static func aboveWater(sink: Double, length: CGFloat, beam: CGFloat) -> Path {
        let amplitude = max(1, beam * 0.12)
        let front = CGFloat(sink) * (length + amplitude * 2) - amplitude
        var path = Path()
        let top = -beam
        let bottom = beam * 2
        path.move(to: CGPoint(x: length + beam, y: top))
        path.addLine(to: CGPoint(x: length + beam, y: bottom))
        var y = bottom
        while y >= top {
            let wobble = amplitude * sin(y / max(beam, 1) * .pi * 2 + CGFloat(sink) * 5)
            path.addLine(to: CGPoint(x: front + wobble, y: y))
            y -= max(1, beam / 6)
        }
        path.closeSubpath()
        return path
    }

    /// The region of the hull the sea still covers while it surfaces: from `surfacing` of the length
    /// (plus a wobble) to the bow.
    private static func underWater(surfacing: Double, length: CGFloat, beam: CGFloat) -> Path {
        let amplitude = max(1, beam * 0.1)
        let front = CGFloat(surfacing) * (length + amplitude * 2) - amplitude
        var path = Path()
        let top = -beam
        let bottom = beam * 2
        path.move(to: CGPoint(x: length + beam, y: top))
        path.addLine(to: CGPoint(x: length + beam, y: bottom))
        var y = bottom
        while y >= top {
            let wobble = amplitude * sin(y / max(beam, 1) * .pi * 1.5 + CGFloat(surfacing) * 4)
            path.addLine(to: CGPoint(x: front + wobble, y: y))
            y -= max(1, beam / 6)
        }
        path.closeSubpath()
        return path
    }

    /// A blackened crater with an ember rim and three scorch streaks on each hit cell (BAT-5), the
    /// same every time for a cell, clipped to the hull.
    @MainActor
    private static func drawCraters(_ cells: Set<Int>, kind: ShipKind, hullPath: Path, box: CGRect, in context: GraphicsContext) {
        let cellLength = box.width / CGFloat(max(kind.length, 1))
        let beam = box.height
        var scorch = context
        scorch.clip(to: hullPath)
        for index in cells.sorted() {
            var generator = SplitMix64(seed: 0xC8A7 &+ UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15)
            let center = CGPoint(
                x: box.minX + (CGFloat(index) + 0.5) * cellLength + CGFloat.random(in: -0.12...0.12, using: &generator) * cellLength,
                y: box.midY + CGFloat.random(in: -0.18...0.18, using: &generator) * beam
            )
            let radius = min(beam * 0.3, cellLength * 0.28)
            // Scorch streaks first, radiating from the crater.
            var streaks = Path()
            for _ in 0..<3 {
                let angle = CGFloat.random(in: 0...(2 * .pi), using: &generator)
                let reach = radius * CGFloat.random(in: 1.6...2.6, using: &generator)
                streaks.move(to: CGPoint(x: center.x + cos(angle) * radius * 0.6, y: center.y + sin(angle) * radius * 0.6))
                streaks.addLine(to: CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach))
            }
            scorch.stroke(streaks, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: max(0.8, radius * 0.3), lineCap: .round))
            scorch.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [.black.opacity(0.9), .black.opacity(0.75), .black.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
            let rim = radius * 0.72
            scorch.stroke(
                Path(ellipseIn: CGRect(x: center.x - rim, y: center.y - rim, width: rim * 2, height: rim * 2)),
                with: .radialGradient(
                    Gradient(colors: [Theme.ember, Theme.flame, Theme.hit.opacity(0.8)]),
                    center: center,
                    startRadius: 0,
                    endRadius: rim
                ),
                lineWidth: max(0.6, radius * 0.18)
            )
        }
    }

    // MARK: Classes

    @MainActor
    private static func drawGunsAndBridge(_ kind: ShipKind, in context: inout GraphicsContext, box: CGRect) {
        let length = box.width
        let beam = box.height
        let midY = box.midY
        func x(_ fraction: CGFloat) -> CGFloat { box.minX + length * fraction }

        switch kind {
        case .battleship:
            turret(at: CGPoint(x: x(0.8), y: midY), radius: beam * 0.2, facing: 1, barrels: 3, reach: beam * 0.42, in: &context)
            turret(at: CGPoint(x: x(0.64), y: midY), radius: beam * 0.23, facing: 1, barrels: 3, reach: beam * 0.32, in: &context)
            superstructure(CGRect(x: x(0.34), y: midY - beam * 0.25, width: length * 0.21, height: beam * 0.5), in: &context)
            funnel(at: CGPoint(x: x(0.4), y: midY), width: length * 0.07, height: beam * 0.3, in: &context)
            mast(at: CGPoint(x: x(0.5), y: midY), radius: beam * 0.1, in: &context)
            turret(at: CGPoint(x: x(0.2), y: midY), radius: beam * 0.23, facing: -1, barrels: 3, reach: beam * 0.5, in: &context)
        case .cruiser:
            turret(at: CGPoint(x: x(0.77), y: midY), radius: beam * 0.2, facing: 1, barrels: 2, reach: beam * 0.4, in: &context)
            turret(at: CGPoint(x: x(0.6), y: midY), radius: beam * 0.22, facing: 1, barrels: 2, reach: beam * 0.3, in: &context)
            superstructure(CGRect(x: x(0.3), y: midY - beam * 0.24, width: length * 0.19, height: beam * 0.48), in: &context)
            funnel(at: CGPoint(x: x(0.36), y: midY), width: length * 0.075, height: beam * 0.28, in: &context)
            mast(at: CGPoint(x: x(0.45), y: midY), radius: beam * 0.09, in: &context)
            turret(at: CGPoint(x: x(0.17), y: midY), radius: beam * 0.22, facing: -1, barrels: 2, reach: beam * 0.4, in: &context)
        case .destroyer:
            turret(at: CGPoint(x: x(0.7), y: midY), radius: beam * 0.21, facing: 1, barrels: 1, reach: beam * 0.5, in: &context)
            superstructure(CGRect(x: x(0.42), y: midY - beam * 0.24, width: length * 0.17, height: beam * 0.48), in: &context)
            funnel(at: CGPoint(x: x(0.34), y: midY), width: length * 0.085, height: beam * 0.28, in: &context)
            // Torpedo tubes on the after deck.
            let tubes = Path { path in
                for offset: CGFloat in [-0.14, 0.14] {
                    path.addRoundedRect(
                        in: CGRect(x: x(0.12), y: midY + beam * offset - beam * 0.05, width: length * 0.15, height: beam * 0.1),
                        cornerSize: CGSize(width: beam * 0.05, height: beam * 0.05)
                    )
                }
            }
            context.fill(tubes, with: .color(Theme.gunMetal))
        case .patrolBoat:
            let cabin = CGRect(x: x(0.28), y: midY - beam * 0.27, width: length * 0.32, height: beam * 0.54)
            superstructure(cabin, in: &context)
            gun(at: CGPoint(x: x(0.74), y: midY), radius: beam * 0.13, in: &context)
        case .carrier, .submarine:
            break
        }
    }

    @MainActor
    private static func drawCarrierDeck(in context: inout GraphicsContext, box: CGRect) {
        let length = box.width
        let beam = box.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: box.minX + length * x, y: box.minY + beam * y)
        }
        let hairline = max(0.5, beam * 0.03)

        // Deck edge lines, the angled landing strip and the centre line.
        var edges = Path()
        edges.move(to: point(0.06, 0.16))
        edges.addLine(to: point(0.86, 0.16))
        edges.move(to: point(0.06, 0.84))
        edges.addLine(to: point(0.62, 0.84))
        context.stroke(edges, with: .color(.white.opacity(0.28)), lineWidth: hairline)

        var landing = Path()
        landing.move(to: point(0.08, 0.72))
        landing.addLine(to: point(0.52, 0.22))
        context.stroke(landing, with: .color(Theme.gold.opacity(0.55)), style: StrokeStyle(lineWidth: hairline, dash: [beam * 0.12, beam * 0.1]))

        var centreLine = Path()
        centreLine.move(to: point(0.1, 0.5))
        centreLine.addLine(to: point(0.93, 0.5))
        context.stroke(centreLine, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: hairline * 1.4, dash: [beam * 0.16, beam * 0.12]))

        // Catapults at the bow.
        var catapults = Path()
        catapults.move(to: point(0.74, 0.36))
        catapults.addLine(to: point(0.95, 0.4))
        catapults.move(to: point(0.74, 0.64))
        catapults.addLine(to: point(0.95, 0.6))
        context.stroke(catapults, with: .color(.white.opacity(0.35)), lineWidth: hairline)

        // Jets parked aft, noses towards the bow.
        let jetSize = beam * 0.2
        for x: CGFloat in [0.16, 0.25, 0.34] {
            let nose = point(x + 0.035, 0.3)
            var jet = Path()
            jet.move(to: nose)
            jet.addLine(to: CGPoint(x: nose.x - jetSize, y: nose.y - jetSize * 0.55))
            jet.addLine(to: CGPoint(x: nose.x - jetSize * 0.78, y: nose.y))
            jet.addLine(to: CGPoint(x: nose.x - jetSize, y: nose.y + jetSize * 0.55))
            jet.closeSubpath()
            context.fill(jet, with: .color(Theme.superstructure.opacity(0.85)))
        }

        // The island, on the starboard edge.
        let island = CGRect(x: box.minX + length * 0.6, y: box.minY + beam * 0.66, width: length * 0.12, height: beam * 0.26)
        superstructure(island, in: &context)
        mast(at: CGPoint(x: island.midX, y: island.midY), radius: beam * 0.07, in: &context)
    }

    @MainActor
    private static func drawSubmarine(in context: inout GraphicsContext, box: CGRect) {
        let length = box.width
        let beam = box.height
        let midY = box.midY
        func x(_ fraction: CGFloat) -> CGFloat { box.minX + length * fraction }

        // Spine and rudder.
        var spine = Path()
        spine.move(to: CGPoint(x: x(0.06), y: midY))
        spine.addLine(to: CGPoint(x: x(0.9), y: midY))
        context.stroke(spine, with: .color(.white.opacity(0.12)), lineWidth: max(0.5, beam * 0.05))
        var rudder = Path()
        rudder.move(to: CGPoint(x: x(0.04), y: midY - beam * 0.32))
        rudder.addLine(to: CGPoint(x: x(0.04), y: midY + beam * 0.32))
        context.stroke(rudder, with: .color(Theme.gunMetal), lineWidth: max(0.8, beam * 0.1))

        // Missile hatches.
        let hatch = beam * 0.09
        for fraction: CGFloat in [0.2, 0.28, 0.36, 0.44] {
            let rect = CGRect(x: x(fraction) - hatch, y: midY - hatch, width: hatch * 2, height: hatch * 2)
            context.fill(Path(ellipseIn: rect), with: .color(Theme.gunMetal.opacity(0.9)))
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.18)), lineWidth: max(0.4, beam * 0.02))
        }

        // The sail, with its diving planes.
        let planes = CGRect(x: x(0.64), y: midY - beam * 0.42, width: length * 0.035, height: beam * 0.84)
        context.fill(Path(roundedRect: planes, cornerRadius: planes.width / 2), with: .color(Theme.gunMetal))
        let sail = CGRect(x: x(0.56), y: midY - beam * 0.2, width: length * 0.19, height: beam * 0.4)
        context.fill(
            Path(roundedRect: sail, cornerRadius: sail.height / 2),
            with: acrossBeam([Theme.gunMetal, Color(red: 0.5, green: 0.56, blue: 0.64), Theme.gunMetal], box: sail)
        )
    }

    @MainActor
    private static func drawWreckage(_ hullPath: Path, box: CGRect, in context: GraphicsContext) {
        // Scorch marks, then a smouldering edge.
        var scorch = context
        scorch.clip(to: hullPath)
        for fraction: CGFloat in [0.22, 0.55, 0.82] {
            let center = CGPoint(x: box.minX + box.width * fraction, y: box.midY)
            let radius = box.height * 0.8
            scorch.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [.black.opacity(0.55), .black.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }
        var ember = context
        ember.addFilter(.shadow(color: Theme.hit.opacity(0.9), radius: max(1, box.height * 0.12)))
        ember.stroke(hullPath, with: .color(Theme.hit.opacity(0.75)), lineWidth: max(0.75, box.height * 0.05))
    }

    // MARK: Parts

    /// A gun turret with its barrels pointing towards the bow (`facing` 1) or the stern (−1).
    @MainActor
    private static func turret(at center: CGPoint, radius: CGFloat, facing: CGFloat, barrels: Int, reach: CGFloat, in context: inout GraphicsContext) {
        let spacing = radius * 0.46
        var guns = Path()
        for index in 0..<barrels {
            let offset = (CGFloat(index) - CGFloat(barrels - 1) / 2) * spacing
            let end = center.x + facing * (radius + reach)
            guns.addRoundedRect(
                in: CGRect(x: min(center.x, end), y: center.y + offset - radius * 0.11, width: abs(end - center.x), height: radius * 0.22),
                cornerSize: CGSize(width: radius * 0.1, height: radius * 0.1)
            )
        }
        context.fill(guns, with: .color(Theme.gunMetal))

        let base = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(
            Path(ellipseIn: base),
            with: .radialGradient(Gradient(colors: [Theme.deck, Theme.gunMetal]), center: center, startRadius: 0, endRadius: radius)
        )
        context.stroke(Path(ellipseIn: base), with: .color(.black.opacity(0.35)), lineWidth: max(0.4, radius * 0.1))
    }

    /// A small deck gun.
    @MainActor
    private static func gun(at center: CGPoint, radius: CGFloat, in context: inout GraphicsContext) {
        let barrel = CGRect(x: center.x, y: center.y - radius * 0.18, width: radius * 2.2, height: radius * 0.36)
        context.fill(Path(barrel), with: .color(Theme.gunMetal))
        let base = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: base), with: .color(Theme.gunMetal))
    }

    @MainActor
    private static func superstructure(_ rect: CGRect, in context: inout GraphicsContext) {
        let corner = min(rect.width, rect.height) * 0.25
        let block = Path(roundedRect: rect, cornerRadius: corner)
        context.fill(block, with: acrossBeam([Theme.deck, Theme.superstructure, Theme.deck], box: rect))
        context.stroke(block, with: .color(.black.opacity(0.3)), lineWidth: max(0.4, rect.height * 0.04))
        // Bridge windows along the forward edge.
        let windows = CGRect(x: rect.maxX - rect.width * 0.2, y: rect.minY + rect.height * 0.18, width: rect.width * 0.08, height: rect.height * 0.64)
        context.fill(Path(windows), with: .color(Theme.gunMetal.opacity(0.85)))
    }

    @MainActor
    private static func funnel(at center: CGPoint, width: CGFloat, height: CGFloat, in context: inout GraphicsContext) {
        let outer = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        context.fill(
            Path(ellipseIn: outer),
            with: .radialGradient(
                Gradient(colors: [Color(red: 0.5, green: 0.54, blue: 0.6), Theme.gunMetal]),
                center: center,
                startRadius: 0,
                endRadius: max(width, height) / 2
            )
        )
        context.stroke(Path(ellipseIn: outer), with: .color(.black.opacity(0.35)), lineWidth: max(0.4, height * 0.06))
        let smoke = outer.insetBy(dx: width * 0.3, dy: height * 0.3)
        context.fill(Path(ellipseIn: smoke), with: .color(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.7)))
    }

    @MainActor
    private static func mast(at center: CGPoint, radius: CGFloat, in context: inout GraphicsContext) {
        var spars = Path()
        spars.move(to: CGPoint(x: center.x, y: center.y - radius * 1.8))
        spars.addLine(to: CGPoint(x: center.x, y: center.y + radius * 1.8))
        context.stroke(spars, with: .color(Theme.gunMetal), lineWidth: max(0.4, radius * 0.3))
        let dome = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: dome), with: .color(.white.opacity(0.9)))
    }

    /// Shading that runs across the beam: `colors` from one side of `box` to the other.
    @MainActor
    private static func acrossBeam(_ colors: [Color], box: CGRect) -> GraphicsContext.Shading {
        .linearGradient(
            Gradient(colors: colors),
            startPoint: CGPoint(x: box.midX, y: box.minY),
            endPoint: CGPoint(x: box.midX, y: box.maxY)
        )
    }
}
