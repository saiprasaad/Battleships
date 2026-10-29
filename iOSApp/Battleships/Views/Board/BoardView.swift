import BattleshipCore
import SwiftUI

/// A square patch of sea with lettered rows and numbered columns. `content` draws on top of it,
/// using the supplied geometry to place things in cells.
struct BoardView<Content: View>: View {
    let rules: Rules
    var showsLabels = true
    /// A cell whose row and column labels light up, such as the one being aimed at.
    var highlighted: Coordinate?
    /// Lights the board's edge, to show it's the one to play on.
    var accent: Color?
    /// Washes some of the colour out of the water, while the board isn't in play.
    var isDimmed = false
    /// How rough the water is, from 0 (calm) to 1. Animate changes at the call site with `.animation(_:value:)`.
    var seaState: Double = 0.2
    /// Ripples where shells have just landed, placed with `BoardGeometry.center(of:)` and timed on `Motion.seconds`.
    var impacts: [WaterImpact] = []
    /// Oil where ships burn and foam where shells splashed, placed and timed like `impacts`.
    var stains: [WaterStain] = []
    /// Off for one still frame of water, for miniatures.
    var isWaterAnimated = true
    /// How much of the corner marks is drawn, 0…1: animate it up from 0 as a board enters.
    var cornerMarksProgress: Double = 1
    @ViewBuilder let content: (BoardGeometry) -> Content

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let geometry = BoardGeometry(boardSize: rules.boardSize, side: side, showsLabels: showsLabels)
            ZStack(alignment: .topLeading) {
                BoardShadow(geometry: geometry, accent: accent)
                WaterView(geometry: geometry, seaState: seaState, impacts: impacts, stains: stains, isAnimated: isWaterAnimated)
                SeaGrid(geometry: geometry, isDetailed: showsLabels, accent: accent, isDimmed: isDimmed)
                if showsLabels {
                    let grid = geometry.gridRect
                    CornerMarks(progress: cornerMarksProgress, inset: 3, arm: min(12, geometry.cell * 0.3))
                        .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle((accent ?? .white).opacity(accent == nil ? 0.3 : 0.85))
                        .frame(width: grid.width, height: grid.height)
                        .offset(x: grid.minX, y: grid.minY)
                        .animation(.easeInOut(duration: 0.4), value: accent)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    BoardLabels(geometry: geometry, highlighted: highlighted)
                }
                content(geometry)
            }
            .frame(width: side, height: side, alignment: .topLeading)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A fine chart grid and a lit bezel over the water, which `WaterView` draws below; the corner marks
/// are `CornerMarks`, above. While the board isn't in play the grid desaturates (animated at the call
/// site's pace), rather than a wash being painted over the water.
struct SeaGrid: View {
    let geometry: BoardGeometry
    var isDetailed = true
    var accent: Color?
    var isDimmed = false

    var body: some View {
        Canvas { context, _ in
            SeaGrid.draw(geometry: geometry, isDetailed: isDetailed, accent: accent, in: context)
        }
        .saturation(isDimmed ? 0.6 : 1)
        .shadow(color: (accent ?? .black).opacity(accent == nil ? 0.35 : 0.4), radius: accent == nil ? 10 : 16)
        .animation(.easeInOut(duration: 0.4), value: accent)
        .animation(.easeInOut(duration: 0.4), value: isDimmed)
        .accessibilityHidden(true)
    }

    private static func draw(geometry: BoardGeometry, isDetailed: Bool, accent: Color?, in context: GraphicsContext) {
        let rect = geometry.gridRect
        guard rect.width > 0 else { return }
        let water = Path(roundedRect: rect, cornerRadius: min(14, geometry.cell * 0.35), style: .continuous)

        // The water itself is WaterView, under this grid. The chart grid, with a dot where lines cross.
        var lines = Path()
        for index in 1..<max(geometry.boardSize, 1) {
            let offset = CGFloat(index) * geometry.cell
            lines.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
            lines.addLine(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            lines.move(to: CGPoint(x: rect.minX, y: rect.minY + offset))
            lines.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + offset))
        }
        context.stroke(lines, with: .color(Theme.gridLine), lineWidth: isDetailed ? 1 : 0.5)

        if isDetailed {
            var dots = Path()
            let radius = max(1, geometry.cell * 0.035)
            for row in 1..<max(geometry.boardSize, 1) {
                for column in 1..<max(geometry.boardSize, 1) {
                    let point = CGPoint(x: rect.minX + CGFloat(column) * geometry.cell, y: rect.minY + CGFloat(row) * geometry.cell)
                    dots.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                }
            }
            context.fill(dots, with: .color(.white.opacity(0.22)))
        }

        // A bezel lit from the top left, brighter when the board is in play.
        let edge = accent ?? Color.white
        context.stroke(
            water,
            with: .linearGradient(
                Gradient(colors: [edge.opacity(accent == nil ? 0.4 : 0.9), edge.opacity(0.15), edge.opacity(accent == nil ? 0.12 : 0.5)]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
            ),
            lineWidth: accent == nil ? 1 : 1.5
        )
    }
}

/// Tactical corner marks just outside the water, like a targeting display: four L-shapes, each drawn
/// from its corner outward along both arms as `progress` runs 0…1, so a board can draw them on as it
/// enters. Give it the grid's frame; the marks sit `inset` points outside it.
struct CornerMarks: Shape {
    var progress: Double = 1
    var inset: CGFloat = 3
    /// The length of each arm.
    var arm: CGFloat = 12

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = CGFloat(min(1, max(0, progress)))
        var path = Path()
        guard p > 0 else { return path }
        let outer = rect.insetBy(dx: -inset, dy: -inset)
        let corners: [(start: CGPoint, vertex: CGPoint, end: CGPoint)] = [
            (CGPoint(x: outer.minX, y: outer.minY + arm), CGPoint(x: outer.minX, y: outer.minY), CGPoint(x: outer.minX + arm, y: outer.minY)),
            (CGPoint(x: outer.maxX - arm, y: outer.minY), CGPoint(x: outer.maxX, y: outer.minY), CGPoint(x: outer.maxX, y: outer.minY + arm)),
            (CGPoint(x: outer.maxX, y: outer.maxY - arm), CGPoint(x: outer.maxX, y: outer.maxY), CGPoint(x: outer.maxX - arm, y: outer.maxY)),
            (CGPoint(x: outer.minX + arm, y: outer.maxY), CGPoint(x: outer.minX, y: outer.maxY), CGPoint(x: outer.minX, y: outer.maxY - arm)),
        ]
        for corner in corners {
            var mark = Path()
            mark.move(to: corner.start)
            mark.addLine(to: corner.vertex)
            mark.addLine(to: corner.end)
            // Both arms are the same length, so trimming about the middle grows them from the vertex.
            path.addPath(p >= 1 ? mark : mark.trimmedPath(from: 0.5 - p / 2, to: 0.5 + p / 2))
        }
        return path
    }
}

/// The board's drop shadow, and its lit edge when `accent` is set, cast by a solid shape under the
/// water: the water redraws every frame, so it can't cast one cheaply.
private struct BoardShadow: View {
    let geometry: BoardGeometry
    var accent: Color?

    var body: some View {
        let rect = geometry.gridRect
        RoundedRectangle(cornerRadius: min(14, geometry.cell * 0.35), style: .continuous)
            .fill(Theme.abyss)
            .frame(width: rect.width, height: rect.height)
            .shadow(color: (accent ?? .black).opacity(accent == nil ? 0.35 : 0.4), radius: accent == nil ? 10 : 16)
            .offset(x: rect.minX, y: rect.minY)
            .animation(.easeInOut(duration: 0.4), value: accent)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Column numbers along the top, row letters down the side. The highlighted cell's labels light in a
/// cascade from the board's edge toward the cell: each label waits 20 ms per cell of distance from
/// the edge (the full tier only).
struct BoardLabels: View {
    let geometry: BoardGeometry
    var highlighted: Coordinate?
    @Environment(\.motionPolicy) private var policy

    /// Seconds per cell of distance from the edge.
    static let cascadeStep: TimeInterval = 0.02

    var body: some View {
        let step = policy.tier == .full ? BoardLabels.cascadeStep : 0
        ZStack(alignment: .topLeading) {
            ForEach(0..<geometry.boardSize, id: \.self) { index in
                let middle = geometry.gutter + (CGFloat(index) + 0.5) * geometry.cell
                let delay = Double(index) * step
                label(Coordinate.columnLabel(index), isLit: highlighted?.column == index)
                    .position(x: middle, y: geometry.gutter / 2 - 1)
                    .animation(.easeOut(duration: 0.2).delay(delay), value: highlighted)
                label(Coordinate.rowLabel(index), isLit: highlighted?.row == index)
                    .position(x: geometry.gutter / 2 - 1, y: middle)
                    .animation(.easeOut(duration: 0.2).delay(delay), value: highlighted)
            }
        }
        .font(.system(size: max(8, min(13, geometry.cell * 0.36)), weight: .bold, design: .rounded))
        .accessibilityHidden(true)
    }

    private func label(_ text: String, isLit: Bool) -> some View {
        Text(text)
            .foregroundStyle(isLit ? AnyShapeStyle(Theme.reticle) : AnyShapeStyle(.secondary))
            .shadow(color: isLit ? Theme.reticle.opacity(0.8) : .clear, radius: 4)
            .scaleEffect(isLit ? 1.2 : 1)
    }
}
