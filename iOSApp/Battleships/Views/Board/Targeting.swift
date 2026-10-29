import BattleshipCore
import SwiftUI

/// The crosshair on the cell the player is aiming at: a turning ring, and brackets that snap
/// shut each time the aim moves.
struct ReticleView: View {
    let cell: CGFloat
    let target: Coordinate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isStill = Motion.holdsStill(reduceMotion: reduceMotion)
        ZStack {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: isStill)) { timeline in
                Circle()
                    .strokeBorder(Theme.reticle.opacity(0.9), style: StrokeStyle(lineWidth: max(1, cell * 0.045), dash: [cell * 0.1, cell * 0.07]))
                    .frame(width: cell * 0.72, height: cell * 0.72)
                    .rotationEffect(.degrees(isStill ? 0 : Motion.cycle(timeline.date, period: 5) * 360))
            }
            LockOnBrackets(cell: cell)
                .id(target)
            Circle()
                .fill(Theme.reticle)
                .frame(width: max(3, cell * 0.1), height: max(3, cell * 0.1))
        }
        .glow(Theme.reticle, radius: cell * 0.18)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
