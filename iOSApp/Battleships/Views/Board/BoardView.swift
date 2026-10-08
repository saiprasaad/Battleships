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
    @ViewBuilder let content: (BoardGeometry) -> Content

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let geometry = BoardGeometry(boardSize: rules.boardSize, side: side, showsLabels: showsLabels)
            ZStack(alignment: .topLeading) {
                SeaGrid(geometry: geometry, isDetailed: showsLabels, accent: accent)
                if showsLabels {
                    BoardLabels(geometry: geometry, highlighted: highlighted)
                }
                content(geometry)
            }
            .frame(width: side, height: side, alignment: .topLeading)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Deep water with a fine chart grid, a lit bezel and tactical corner marks.
struct SeaGrid: View {
    let geometry: BoardGeometry
    var isDetailed = true
    var accent: Color?

    var body: some View {
        Canvas { context, _ in
            SeaGrid.draw(geometry: geometry, isDetailed: isDetailed, accent: accent, in: context)
        }
        .shadow(color: (accent ?? .black).opacity(accent == nil ? 0.35 : 0.4), radius: accent == nil ? 10 : 16)
        .animation(.easeInOut(duration: 0.4), value: accent)
        .accessibilityHidden(true)
    }

    private static func draw(geometry: BoardGeometry, isDetailed: Bool, accent: Color?, in context: GraphicsContext) {
        let rect = geometry.gridRect
        guard rect.width > 0 else { return }
        let water = Path(roundedRect: rect, cornerRadius: min(14, geometry.cell * 0.35), style: .continuous)

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

        // The chart grid, with a dot where lines cross.
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

        // Corner marks just outside the water, like a targeting display.
        guard isDetailed else { return }
        let inset: CGFloat = 4
        let arm = min(16, geometry.cell * 0.45)
        let outer = rect.insetBy(dx: -inset, dy: -inset)
        var corners = Path()
        corners.move(to: CGPoint(x: outer.minX, y: outer.minY + arm))
        corners.addLine(to: CGPoint(x: outer.minX, y: outer.minY))
        corners.addLine(to: CGPoint(x: outer.minX + arm, y: outer.minY))
        corners.move(to: CGPoint(x: outer.maxX - arm, y: outer.minY))
        corners.addLine(to: CGPoint(x: outer.maxX, y: outer.minY))
        corners.addLine(to: CGPoint(x: outer.maxX, y: outer.minY + arm))
        corners.move(to: CGPoint(x: outer.maxX, y: outer.maxY - arm))
        corners.addLine(to: CGPoint(x: outer.maxX, y: outer.maxY))
        corners.addLine(to: CGPoint(x: outer.maxX - arm, y: outer.maxY))
        corners.move(to: CGPoint(x: outer.minX + arm, y: outer.maxY))
        corners.addLine(to: CGPoint(x: outer.minX, y: outer.maxY))
        corners.addLine(to: CGPoint(x: outer.minX, y: outer.maxY - arm))
        context.stroke(
            corners,
            with: .color((accent ?? .white).opacity(accent == nil ? 0.3 : 0.85)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )
    }
}

/// Column numbers along the top, row letters down the side.
struct BoardLabels: View {
    let geometry: BoardGeometry
    var highlighted: Coordinate?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<geometry.boardSize, id: \.self) { index in
                let middle = geometry.gutter + (CGFloat(index) + 0.5) * geometry.cell
                label(Coordinate.columnLabel(index), isLit: highlighted?.column == index)
                    .position(x: middle, y: geometry.gutter / 2 - 1)
                label(Coordinate.rowLabel(index), isLit: highlighted?.row == index)
                    .position(x: geometry.gutter / 2 - 1, y: middle)
            }
        }
        .font(.system(size: max(8, min(13, geometry.cell * 0.36)), weight: .bold, design: .rounded))
        .animation(.easeOut(duration: 0.2), value: highlighted)
        .accessibilityHidden(true)
    }

    private func label(_ text: String, isLit: Bool) -> some View {
        Text(text)
            .foregroundStyle(isLit ? AnyShapeStyle(Theme.reticle) : AnyShapeStyle(.secondary))
            .shadow(color: isLit ? Theme.reticle.opacity(0.8) : .clear, radius: 4)
            .scaleEffect(isLit ? 1.2 : 1)
    }
}

/// The result of a shot, drawn in its cell.
struct CellMarkView: View {
    let mark: CellMark
    let cell: CGFloat
    /// A hit on a ship the player can't see yet gets a halo so it stands out on open water.
    var showsHitGlow = false
    /// The fleet miniature draws plain dots, which read better at that size.
    var isMiniature = false

    var body: some View {
        symbol(for: mark)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func symbol(for mark: CellMark) -> some View {
        if isMiniature {
            Circle()
                .fill(miniatureColor)
                .frame(width: cell * 0.5, height: cell * 0.5)
                .shadow(color: mark == .miss ? .clear : Theme.hit, radius: cell * 0.2)
        } else {
            switch mark {
            case .miss:
                SplashMark(cell: cell)
            case .hit:
                FlameMark(cell: cell, showsHalo: showsHitGlow)
            case .sunk:
                FlameMark(cell: cell, scale: 0.7, showsHalo: false)
                    .opacity(0.8)
            }
        }
    }

    private var miniatureColor: Color {
        switch mark {
        case .miss: .white.opacity(0.7)
        case .hit: Theme.flame
        case .sunk: Theme.hit
        }
    }
}

/// Where a shell fell into open water.
private struct SplashMark: View {
    let cell: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: max(0.75, cell * 0.03))
                .frame(width: cell * 0.52, height: cell * 0.52)
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: cell * 0.18, height: cell * 0.18)
                .shadow(color: .white.opacity(0.7), radius: cell * 0.1)
        }
    }
}

/// A fire burning where a shell struck a ship. It flickers, unless Reduce Motion is on.
struct FlameMark: View {
    let cell: CGFloat
    var scale: CGFloat = 1
    var showsHalo = true
    @State private var flicker = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if showsHalo {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.flame.opacity(0.6), Theme.hit.opacity(0.25), Theme.hit.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: cell * 0.5
                        )
                    )
                    .frame(width: cell, height: cell)
                    .scaleEffect(flicker ? 1.08 : 0.92)
            }
            Image(systemName: "flame.fill")
                .font(.system(size: cell * 0.52 * scale))
                .foregroundStyle(LinearGradient(colors: [Theme.ember, Theme.flame, Theme.hit], startPoint: .top, endPoint: .bottom))
                .scaleEffect(x: flicker ? 0.94 : 1.04, y: flicker ? 1.08 : 0.94, anchor: .bottom)
                .shadow(color: Theme.flame.opacity(0.9), radius: cell * 0.12 * scale)
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: .random(in: 0.14...0.24)).repeatForever(autoreverses: true)) {
                flicker = true
            }
        }
    }
}

/// The crosshair on the cell the player is aiming at: a turning ring, and brackets that snap
/// shut each time the aim moves.
struct ReticleView: View {
    let cell: CGFloat
    let target: Coordinate
    @State private var spin = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.reticle.opacity(0.9), style: StrokeStyle(lineWidth: max(1, cell * 0.045), dash: [cell * 0.1, cell * 0.07]))
                .frame(width: cell * 0.72, height: cell * 0.72)
                .rotationEffect(.degrees(spin))
            LockOnBrackets(cell: cell)
                .id(target)
            Circle()
                .fill(Theme.reticle)
                .frame(width: max(3, cell * 0.1), height: max(3, cell * 0.1))
        }
        .glow(Theme.reticle, radius: cell * 0.18)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) {
                spin = 360
            }
        }
    }
}

private struct LockOnBrackets: View {
    let cell: CGFloat
    @State private var isLocked = false

    var body: some View {
        CornerBrackets()
            .stroke(Theme.reticle, style: StrokeStyle(lineWidth: max(1.5, cell * 0.06), lineCap: .round, lineJoin: .round))
            .frame(width: cell * 0.96, height: cell * 0.96)
            .scaleEffect(isLocked ? 1 : 1.9)
            .opacity(isLocked ? 1 : 0)
            .onAppear {
                withAnimation(.spring(duration: 0.4, bounce: 0.45)) {
                    isLocked = true
                }
            }
    }
}

/// Four L-shaped marks at the corners of a square.
struct CornerBrackets: Shape {
    var arm: CGFloat = 0.28

    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * arm
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        return path
    }
}

/// Light bands and laser lines along the aimed row and column.
struct AimGuides: View {
    let geometry: BoardGeometry
    let target: Coordinate

    var body: some View {
        let cell = geometry.rect(for: target)
        let grid = geometry.gridRect
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.reticle.opacity(0.1))
                .frame(width: grid.width, height: cell.height)
                .position(x: grid.midX, y: cell.midY)
            Rectangle()
                .fill(Theme.reticle.opacity(0.1))
                .frame(width: cell.width, height: grid.height)
                .position(x: cell.midX, y: grid.midY)
            Rectangle()
                .fill(laser(.horizontal))
                .frame(width: grid.width, height: 1)
                .position(x: grid.midX, y: cell.midY)
            Rectangle()
                .fill(laser(.vertical))
                .frame(width: 1, height: grid.height)
                .position(x: cell.midX, y: grid.midY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func laser(_ axis: Axis) -> LinearGradient {
        LinearGradient(
            colors: [Theme.reticle.opacity(0), Theme.reticle.opacity(0.55), Theme.reticle.opacity(0)],
            startPoint: axis == .horizontal ? .leading : .top,
            endPoint: axis == .horizontal ? .trailing : .bottom
        )
    }
}
