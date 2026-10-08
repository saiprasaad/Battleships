import BattleshipCore
import SwiftUI

/// A square patch of sea with lettered rows and numbered columns. `content` draws on top of it,
/// using the supplied geometry to place things in cells.
struct BoardView<Content: View>: View {
    let rules: Rules
    var showsLabels = true
    @ViewBuilder let content: (BoardGeometry) -> Content

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let geometry = BoardGeometry(boardSize: rules.boardSize, side: side, showsLabels: showsLabels)
            ZStack(alignment: .topLeading) {
                SeaGrid(geometry: geometry)
                if showsLabels {
                    BoardLabels(geometry: geometry)
                }
                content(geometry)
            }
            .frame(width: side, height: side, alignment: .topLeading)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The water and grid lines.
struct SeaGrid: View {
    let geometry: BoardGeometry

    var body: some View {
        Canvas { context, _ in
            let rect = geometry.gridRect
            let water = Path(roundedRect: rect, cornerRadius: min(12, geometry.cell * 0.3))
            context.fill(
                water,
                with: .linearGradient(
                    Gradient(colors: [Theme.seaTop, Theme.seaBottom]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )

            var lines = Path()
            for index in 1..<max(geometry.boardSize, 1) {
                let offset = CGFloat(index) * geometry.cell
                lines.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
                lines.addLine(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
                lines.move(to: CGPoint(x: rect.minX, y: rect.minY + offset))
                lines.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + offset))
            }
            context.stroke(lines, with: .color(Theme.gridLine), lineWidth: 1)
            context.stroke(water, with: .color(.white.opacity(0.2)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// Column numbers along the top, row letters down the side.
struct BoardLabels: View {
    let geometry: BoardGeometry

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<geometry.boardSize, id: \.self) { index in
                let middle = geometry.gutter + (CGFloat(index) + 0.5) * geometry.cell
                Text(Coordinate.columnLabel(index))
                    .position(x: middle, y: geometry.gutter / 2)
                Text(Coordinate.rowLabel(index))
                    .position(x: geometry.gutter / 2, y: middle)
            }
        }
        .font(.system(size: max(8, min(13, geometry.cell * 0.38)), weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.boardLabel)
        .accessibilityHidden(true)
    }
}

/// A ship's hull: rounded at the stern, pointed at the bow (right for horizontal ships, bottom for vertical).
struct HullShape: Shape {
    var isVertical: Bool

    func path(in rect: CGRect) -> Path {
        let length = isVertical ? rect.height : rect.width
        let beam = isVertical ? rect.width : rect.height
        let bow = min(beam * 0.9, length * 0.4)
        let stern = min(beam / 2, length * 0.3)

        // Drawn lying horizontally, then turned upright for vertical ships.
        var hull = Path()
        hull.move(to: CGPoint(x: stern, y: 0))
        hull.addLine(to: CGPoint(x: length - bow, y: 0))
        hull.addQuadCurve(to: CGPoint(x: length, y: beam / 2), control: CGPoint(x: length - bow * 0.2, y: 0))
        hull.addQuadCurve(to: CGPoint(x: length - bow, y: beam), control: CGPoint(x: length - bow * 0.2, y: beam))
        hull.addLine(to: CGPoint(x: stern, y: beam))
        hull.addQuadCurve(to: CGPoint(x: 0, y: beam / 2), control: CGPoint(x: 0, y: beam))
        hull.addQuadCurve(to: CGPoint(x: stern, y: 0), control: CGPoint(x: 0, y: 0))
        hull.closeSubpath()

        if isVertical {
            // (x, y) → (beam − y, x): the stern ends up at the top, the bow at the bottom.
            hull = hull.applying(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: beam, ty: 0))
        }
        return hull.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// A ship drawn to fill its frame.
struct ShipView: View {
    let ship: ShipPlacement
    var isSunk = false
    var isHighlighted = false

    var body: some View {
        let vertical = ship.orientation == .vertical
        ZStack {
            HullShape(isVertical: vertical)
                .fill(
                    LinearGradient(
                        colors: isSunk ? [Theme.wreck, Theme.wreck.opacity(0.75)] : [Theme.hull, Theme.hullShadow],
                        startPoint: vertical ? .leading : .top,
                        endPoint: vertical ? .trailing : .bottom
                    )
                )
            DeckDetail(length: ship.length, isVertical: vertical)
                .opacity(isSunk ? 0.25 : 0.5)
            HullShape(isVertical: vertical)
                .stroke(isHighlighted ? Theme.reticle : Color.black.opacity(0.3), lineWidth: isHighlighted ? 2.5 : 1)
        }
        .shadow(color: .black.opacity(isSunk ? 0.1 : 0.35), radius: 3, y: 2)
        .opacity(isSunk ? 0.85 : 1)
    }
}

/// Gun turrets along the centre line.
private struct DeckDetail: View {
    let length: Int
    let isVertical: Bool

    var body: some View {
        Canvas { context, size in
            let beam = isVertical ? size.width : size.height
            let segment = (isVertical ? size.height : size.width) / CGFloat(length)
            let diameter = beam * 0.32
            for index in 0..<length {
                let along = segment * (CGFloat(index) + 0.42)
                let center = isVertical ? CGPoint(x: beam / 2, y: along) : CGPoint(x: along, y: beam / 2)
                let dot = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
                context.fill(Path(ellipseIn: dot), with: .color(.black))
            }
        }
    }
}

/// The result of a shot, drawn in its cell.
struct CellMarkView: View {
    let mark: CellMark
    let cell: CGFloat
    /// A hit on a ship the player can't see yet gets a red glow so it stands out on open water.
    var showsHitGlow = false

    var body: some View {
        switch mark {
        case .miss:
            ZStack {
                Circle()
                    .stroke(Theme.spray.opacity(0.35), lineWidth: 1)
                    .frame(width: cell * 0.56, height: cell * 0.56)
                Circle()
                    .fill(Theme.spray)
                    .frame(width: cell * 0.22, height: cell * 0.22)
            }
        case .hit:
            ZStack {
                if showsHitGlow {
                    Circle()
                        .fill(Theme.hit.opacity(0.3))
                        .frame(width: cell * 0.82, height: cell * 0.82)
                }
                Image(systemName: "flame.fill")
                    .font(.system(size: cell * 0.5))
                    .foregroundStyle(LinearGradient(colors: [Theme.flame, Theme.hit], startPoint: .top, endPoint: .bottom))
            }
        case .sunk:
            Image(systemName: "xmark")
                .font(.system(size: cell * 0.42, weight: .black))
                .foregroundStyle(Theme.hit)
        }
    }
}

/// The pulsing crosshair on the cell the player is aiming at.
struct ReticleView: View {
    let cell: CGFloat

    var body: some View {
        Image(systemName: "scope")
            .font(.system(size: cell * 0.82, weight: .semibold))
            .foregroundStyle(Theme.reticle)
            .shadow(color: Theme.reticle.opacity(0.8), radius: 6)
            .symbolEffect(.pulse, options: .repeating)
            .allowsHitTesting(false)
    }
}

/// A splash or an explosion where a shell just landed.
struct ImpactView: View {
    let isHit: Bool
    let cell: CGFloat
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            if isHit {
                Circle()
                    .fill(RadialGradient(colors: [.yellow, Theme.flame, Theme.hit.opacity(0)], center: .center, startRadius: 0, endRadius: cell * 1.2))
                    .frame(width: cell * 2.4, height: cell * 2.4)
                    .scaleEffect(0.3 + progress * 0.9)
                    .opacity(1 - progress)
            }
            Circle()
                .stroke(isHit ? Theme.flame : Theme.spray, lineWidth: 2)
                .frame(width: cell * 2, height: cell * 2)
                .scaleEffect(0.2 + progress)
                .opacity(1 - progress)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) {
                progress = 1
            }
        }
    }
}
