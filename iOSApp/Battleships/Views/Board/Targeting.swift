import BattleshipCore
import SwiftUI

/// The lock-on's beats, in seconds (BAT-7).
enum LockOnBeat {
    /// The scan line sweeping the cell.
    static let scan: TimeInterval = 0.22
    /// The sonar ring expanding from the cell to 2.5 cells.
    static let ring: TimeInterval = 0.5
    /// The aim guides drawing out from the cell to the board's edges.
    static let guides: TimeInterval = 0.2
    /// The squeeze of the brackets on the second tap: in, then the spring back.
    static let squeeze: TimeInterval = 0.08
    static let squeezeRecover: TimeInterval = 0.2
    /// Each step of the refused reticle's shake.
    static let shakeStep: TimeInterval = 0.04
    /// The laser dashes' trip from the board's edge to the reticle.
    static let dashPeriod: Double = 1.4
}

/// The crosshair on the cell the player is aiming at: a turning ring, brackets that snap shut each
/// time the aim moves, a scan line and one sonar ring on each new aim, and the dashes travelling
/// along the aim guides' lasers toward it, all on the ring's one ambient clock. `squeeze` bumps on
/// the second tap on the aimed cell (the brackets flash and clench), `refusal` when the player aims
/// at a cell already fired at (the reticle shakes and flashes red). Policy-gated throughout: the
/// still tier shows the ring, dot and brackets at rest.
struct ReticleView: View {
    let geometry: BoardGeometry
    let target: Coordinate
    var squeeze = 0
    var refusal = 0
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let cell = geometry.cell
        let moves = policy.tier != .still
        ZStack {
            // The dashes and the turning ring share one ambient clock: no second loop while aiming.
            LoopClock(loop: .ambient) { seconds in
                ZStack {
                    if let seconds, moves {
                        LaserDashes(geometry: geometry, target: target, seconds: seconds)
                    }
                    Circle()
                        .strokeBorder(Theme.reticle.opacity(0.9), style: StrokeStyle(lineWidth: max(1, cell * 0.045), dash: [cell * 0.1, cell * 0.07]))
                        .frame(width: cell * 0.72, height: cell * 0.72)
                        .rotationEffect(.degrees(seconds.map { Motion.cycle($0, period: 5) * 360 } ?? 0))
                }
            }
            if moves {
                // One sonar ring out to 2.5 cells, and a scan line down the cell, on each new aim.
                OneShot(trigger: target, duration: LockOnBeat.ring, playsOnAppear: true) { progress in
                    let diameter: CGFloat = cell * CGFloat(0.3 + 2.2 * progress)
                    Circle()
                        .stroke(Theme.reticle.opacity(0.8 * (1 - progress)), lineWidth: max(1, cell * 0.04))
                        .frame(width: diameter, height: diameter)
                }
                OneShot(trigger: target, duration: LockOnBeat.scan, playsOnAppear: true) { progress in
                    Rectangle()
                        .fill(Theme.reticle.opacity(progress < 1 ? 0.85 : 0))
                        .frame(width: cell * 0.9, height: max(1, cell * 0.04))
                        .offset(y: -cell * 0.45 + progress * cell * 0.9)
                }
            }
            LockOnBrackets(cell: cell, squeeze: squeeze)
                .id(target)
            Circle()
                .fill(Theme.reticle)
                .frame(width: max(3, cell * 0.1), height: max(3, cell * 0.1))
        }
        .modifier(ReticleRefusal(trigger: refusal, cell: cell))
        .glow(Theme.reticle, radius: cell * 0.18)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Four short bright dashes travelling along the aimed row and column from the board's edges to the
/// reticle, converging once every `LockOnBeat.dashPeriod` seconds. Placed about the cell's centre.
private struct LaserDashes: View {
    let geometry: BoardGeometry
    let target: Coordinate
    let seconds: Double

    var body: some View {
        let cell = geometry.cell
        let grid = geometry.gridRect
        let center = geometry.center(of: target)
        let progress = Motion.easeOut(Motion.cycle(seconds, period: LockOnBeat.dashPeriod))
        let fade = sin(progress * .pi)
        let arms: [(dx: CGFloat, dy: CGFloat, reach: CGFloat)] = [
            (-1, 0, center.x - grid.minX - cell / 2),
            (1, 0, grid.maxX - center.x - cell / 2),
            (0, -1, center.y - grid.minY - cell / 2),
            (0, 1, grid.maxY - center.y - cell / 2),
        ]
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                let arm = arms[index]
                let length = min(cell * 0.9, arm.reach)
                let travel = max(0, arm.reach - length)
                let distance = cell / 2 + length / 2 + travel * (1 - CGFloat(progress))
                Capsule()
                    .fill(Theme.reticle)
                    .frame(width: arm.dx == 0 ? 1.5 : length, height: arm.dx == 0 ? length : 1.5)
                    .offset(x: arm.dx * distance, y: arm.dy * distance)
                    .opacity(arm.reach > cell * 0.3 ? 0.9 * fade : 0)
            }
        }
    }
}

private struct SqueezePose {
    var scale: CGFloat = 1
    var flash: Double = 0
}

/// The brackets that snap shut on the aimed cell on `Motion.Curve.slam` (the still tier shows them at
/// once), and clench to 0.8 with a white flash when `squeeze` bumps.
private struct LockOnBrackets: View {
    let cell: CGFloat
    var squeeze = 0
    @State private var isLocked = false
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let snaps = policy.tier == .full
        let flashes = policy.allowsFlashes
        KeyframeAnimator(initialValue: SqueezePose(), trigger: squeeze) { pose in
            CornerBrackets()
                .stroke(Theme.reticle, style: StrokeStyle(lineWidth: max(1.5, cell * 0.06), lineCap: .round, lineJoin: .round))
                .overlay {
                    CornerBrackets()
                        .stroke(flashes ? Color.white : Theme.reticle, style: StrokeStyle(lineWidth: max(1.5, cell * 0.06), lineCap: .round, lineJoin: .round))
                        .opacity(pose.flash)
                }
                .frame(width: cell * 0.96, height: cell * 0.96)
                .scaleEffect(pose.scale)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(snaps ? 0.8 : 1, duration: LockOnBeat.squeeze)
                SpringKeyframe(1, duration: LockOnBeat.squeezeRecover, spring: .bouncy)
            }
            KeyframeTrack(\.flash) {
                LinearKeyframe(1, duration: 0.03)
                LinearKeyframe(0, duration: 0.12)
            }
        }
        .scaleEffect(isLocked || !snaps ? 1 : 1.9)
        .opacity(isLocked ? 1 : 0)
        .onAppear {
            withAnimation(Motion.Curve.slam.policy(policy)) {
                isLocked = true
            }
        }
    }
}

private struct RefusalPose {
    var dx: CGFloat = 0
    var red: Double = 0
}

/// The reticle refused: two 3 pt jolts and a red ring, each time `trigger` changes. The jolts need
/// the policy's shakes; the red ring its flashes.
private struct ReticleRefusal: ViewModifier {
    let trigger: Int
    let cell: CGFloat
    @Environment(\.motionPolicy) private var policy

    func body(content: Content) -> some View {
        let amplitude: CGFloat = policy.allowsShake ? 3 : 0
        let red: Double = policy.allowsFlashes ? 1 : 0
        KeyframeAnimator(initialValue: RefusalPose(), trigger: trigger) { pose in
            content
                .offset(x: pose.dx)
                .overlay {
                    Circle()
                        .stroke(Theme.hit, lineWidth: max(1.5, cell * 0.05))
                        .frame(width: cell * 0.96, height: cell * 0.96)
                        .opacity(pose.red)
                }
        } keyframes: { _ in
            KeyframeTrack(\.dx) {
                LinearKeyframe(amplitude, duration: LockOnBeat.shakeStep)
                LinearKeyframe(-amplitude, duration: LockOnBeat.shakeStep)
                LinearKeyframe(amplitude, duration: LockOnBeat.shakeStep)
                LinearKeyframe(-amplitude, duration: LockOnBeat.shakeStep)
                LinearKeyframe(0, duration: LockOnBeat.shakeStep)
            }
            KeyframeTrack(\.red) {
                LinearKeyframe(red, duration: 0.04)
                LinearKeyframe(red, duration: 0.1)
                LinearKeyframe(0, duration: 0.16)
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

/// Light bands and laser lines along the aimed row and column. The lines draw outward from the cell
/// to the board's edges over `LockOnBeat.guides` on each new aim (the still tier shows them at once).
struct AimGuides: View {
    let geometry: BoardGeometry
    let target: Coordinate

    var body: some View {
        let cell = geometry.rect(for: target)
        let grid = geometry.gridRect
        OneShot(trigger: target, duration: LockOnBeat.guides, playsOnAppear: true) { progress in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Theme.reticle.opacity(0.1 * progress))
                    .frame(width: grid.width, height: cell.height)
                    .position(x: grid.midX, y: cell.midY)
                Rectangle()
                    .fill(Theme.reticle.opacity(0.1 * progress))
                    .frame(width: cell.width, height: grid.height)
                    .position(x: cell.midX, y: grid.midY)
                GuideLines(geometry: geometry, target: target, axis: .horizontal, progress: progress)
                    .stroke(laser(.horizontal), lineWidth: 1)
                GuideLines(geometry: geometry, target: target, axis: .vertical, progress: progress)
                    .stroke(laser(.vertical), lineWidth: 1)
            }
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

/// The two laser segments of one axis, from the aimed cell's edges out to the grid's edges, each
/// `progress` of its length long.
private struct GuideLines: Shape {
    let geometry: BoardGeometry
    let target: Coordinate
    let axis: Axis
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in _: CGRect) -> Path {
        let cell = geometry.rect(for: target)
        let grid = geometry.gridRect
        let p = CGFloat(min(1, max(0, progress)))
        var path = Path()
        switch axis {
        case .horizontal:
            path.move(to: CGPoint(x: cell.minX, y: cell.midY))
            path.addLine(to: CGPoint(x: cell.minX - (cell.minX - grid.minX) * p, y: cell.midY))
            path.move(to: CGPoint(x: cell.maxX, y: cell.midY))
            path.addLine(to: CGPoint(x: cell.maxX + (grid.maxX - cell.maxX) * p, y: cell.midY))
        case .vertical:
            path.move(to: CGPoint(x: cell.midX, y: cell.minY))
            path.addLine(to: CGPoint(x: cell.midX, y: cell.minY - (cell.minY - grid.minY) * p))
            path.move(to: CGPoint(x: cell.midX, y: cell.maxY))
            path.addLine(to: CGPoint(x: cell.midX, y: cell.maxY + (grid.maxY - cell.maxY) * p))
        }
        return path
    }
}

// MARK: - The turn handoff (BAT-6)

/// A band of light running round the water's edge each time `trigger` changes: clockwise in
/// `Theme.reticle` as the turn returns, counter-clockwise and dim as it leaves, gold or red at the end
/// of the battle. 450 ms, over `SeaGrid`'s own bezel. Nothing in the still tier. (The placement
/// board's lock sweep is `BezelSweep`; this is the battle's.)
struct TurnBezelSweep<Trigger: Equatable>: View {
    let geometry: BoardGeometry
    var tint: Color = Theme.reticle
    let trigger: Trigger
    var clockwise = true
    @Environment(\.motionPolicy) private var policy

    /// How long the sweep takes.
    static var length: TimeInterval { 0.45 }
    /// How much of the perimeter the band covers.
    private static var band: Double { 0.3 }

    var body: some View {
        let rect = geometry.gridRect
        let radius = min(14, geometry.cell * 0.35)
        OneShot(trigger: trigger, duration: Self.length) { progress in
            let head = progress * (1 + Self.band)
            let from = max(0, head - Self.band)
            let to = min(1, head)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .trim(from: clockwise ? from : 1 - to, to: clockwise ? to : 1 - from)
                .stroke(tint.opacity(progress < 1 ? 0.95 : 0), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: rect.width, height: rect.height)
                .glow(policy.allowsFlashes && progress < 1 ? tint : .clear, radius: 6)
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The one grid sweep in the game: a one-cell-tall white band running down the water as the turn
/// returns, 12 % white (8 % without flashes), each time `trigger` changes. Nothing in the still tier.
struct GridSweep<Trigger: Equatable>: View {
    let geometry: BoardGeometry
    let trigger: Trigger
    @Environment(\.motionPolicy) private var policy

    /// How long the band takes to cross the board.
    static var length: TimeInterval { 0.6 }

    var body: some View {
        let grid = geometry.gridRect
        let cell = geometry.cell
        let peak = policy.allowsFlashes ? 0.12 : 0.08
        OneShot(trigger: trigger, duration: Self.length) { progress in
            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(peak), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: grid.width, height: cell)
                .position(x: grid.midX, y: grid.minY - cell + progress * (grid.height + cell * 2))
                .opacity(progress < 1 ? 1 : 0)
        }
        .clipShape(
            RoundedRectangle(cornerRadius: min(14, cell * 0.35), style: .continuous)
                .size(width: grid.width, height: grid.height)
                .offset(x: grid.minX, y: grid.minY)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
