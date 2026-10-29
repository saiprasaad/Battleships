import BattleshipCore
import SwiftUI

/// The player's shells in the air, drawn above the whole battle (BAT-1): each leaves the Fire button
/// for the cell it is aimed at along an arc, a bright head with an additive tail and a shadow on the
/// water beneath it. The host (`BattleView`) reads the battle's anchors and hands the layer the Fire
/// button's frame and a way to find each cell's frame, both in the layer's own coordinates:
///
///     overlayPreferenceValue(BattleAnchors.self) { anchors in
///         GeometryReader { proxy in
///             ShellFlightLayer(
///                 shells: controller.shells, clock: controller.targetClock,
///                 from: anchors[.fireButton].map { proxy[$0] },
///                 to: { cell in anchors[.targetCell(cell)].map { proxy[$0] } }
///             )
///         }
///     }
///
/// One `EffectTimeline` and one Canvas for every shell, only while one is in the air. Everything is a
/// function of the shell's dates: it rises to the apex over `Timing.apexHold`, waits there while an
/// online shot has no landing yet (dimming to half with a slow pulse once it has waited longer than
/// `Timing.apexTimeout`: TRANSMITTING), descends to land at `lands`, or fizzles (drops and fades over
/// `BattleController.misfireLinger`) when the request failed. The closing ring on the cell is the
/// board's `EffectsLayer`'s. The still tier draws nothing (the ring is the shell there); the reduced
/// tier draws the arc without the head's blur.
struct ShellFlightLayer: View {
    let shells: [ShellFlight]
    let clock: FXClock
    /// The Fire button's frame, or nil when it isn't on screen (then nothing flies).
    let from: CGRect?
    /// The frame of the cell a shell is heading for, or nil when the board isn't showing it.
    let to: @MainActor (Coordinate) -> CGRect?
    @Environment(\.motionPolicy) private var policy
    /// When each misfired shell began to fizzle, by its id: the controller marks the misfire but
    /// publishes no date for it.
    @State private var fizzles: [UUID: Date] = [:]

    /// Seconds of positions the tail covers.
    static let tailLength: TimeInterval = 0.06
    /// The frame interval while every shell is held at the apex, waiting for the server.
    static let holdingInterval: TimeInterval = 1 / 20

    var body: some View {
        let live = shells.filter { $0.board == .target }
        let targets: [Coordinate: CGRect] = live.reduce(into: [:]) { targets, shell in
            if targets[shell.coordinate] == nil, let rect = to(shell.coordinate) {
                targets[shell.coordinate] = rect
            }
        }
        let isHolding = !live.isEmpty && live.allSatisfy { $0.lands == nil && $0.outcome != .misfire }
        let interval = isHolding ? Self.holdingInterval : policy.effectsInterval
        let draws = !live.isEmpty && policy.tier != .still && from != nil
        ZStack {
            if draws, let from {
                EffectTimeline(clock: clock, frameInterval: interval) { effectTime in
                    let frame = makeFrame(at: effectTime, shells: live, from: from, targets: targets)
                    Canvas(rendersAsynchronously: true) { context, _ in
                        ShellFlightLayer.draw(frame, in: &context)
                    }
                }
            }
        }
        .onChange(of: shells, initial: true) { _, shells in
            noteFizzles(shells)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Remembers when each misfire began, and forgets shells that have gone.
    private func noteFizzles(_ shells: [ShellFlight]) {
        var kept: [UUID: Date] = [:]
        for shell in shells where shell.outcome == .misfire {
            kept[shell.id] = fizzles[shell.id] ?? Date()
        }
        if kept != fizzles {
            fizzles = kept
        }
    }

    // MARK: The frame

    /// What one frame draws, in the layer's points. Sendable, so the Canvas captures nothing else.
    struct Frame: Sendable {
        struct Shell: Sendable {
            var head: CGPoint
            /// The last `tailLength` seconds of positions, oldest first.
            var tail: [CGPoint]
            /// On the water beneath the head.
            var shadow: CGPoint
            var shadowOpacity: Double
            var shadowRadius: CGFloat
            var headScale: CGFloat
            var opacity: Double
        }

        var shells: [Shell] = []
        var flashes: Bool
        /// The head's soft halo through a blurred layer: the full tier only.
        var blurs: Bool
    }

    private func makeFrame(at effectTime: TimeInterval, shells: [ShellFlight], from: CGRect, targets: [Coordinate: CGRect]) -> Frame {
        var frame = Frame(flashes: policy.allowsFlashes, blurs: policy.tier == .full)
        let launch = CGPoint(x: from.midX, y: from.minY + from.height * 0.25)
        for shell in shells {
            guard let target = targets[shell.coordinate] else { continue }
            let destination = CGPoint(x: target.midX, y: target.midY)
            let start = clock.time(at: shell.start)
            let lands = shell.lands.map { clock.time(at: $0) }
            let elapsed = effectTime - start
            guard elapsed >= 0 else { continue }

            var drop: CGFloat = 0
            var opacity = 1.0
            if shell.outcome == .misfire {
                let since = fizzles[shell.id].map { effectTime - clock.time(at: $0) } ?? 0
                let fizzle = min(1, max(0, since / BattleController.misfireLinger))
                drop = 10 * CGFloat(fizzle)
                opacity = 1 - fizzle
            } else if lands == nil, elapsed > Timing.apexTimeout {
                // TRANSMITTING: held at the apex, dimmed, with a slow holding pulse.
                opacity = 0.5 + 0.1 * sin(elapsed * 2 * .pi / 0.8)
            }
            guard opacity > 0 else { continue }

            let u = Self.progress(elapsed: elapsed, flight: lands.map { $0 - start })
            let head = Self.point(from: launch, to: destination, at: u)
            var tail: [CGPoint] = []
            let steps = 6
            for step in stride(from: steps, through: 1, by: -1) {
                let earlier = elapsed - Self.tailLength * Double(step) / Double(steps)
                guard earlier >= 0 else { continue }
                tail.append(Self.point(from: launch, to: destination, at: Self.progress(elapsed: earlier, flight: lands.map { $0 - start })))
            }
            let descent = max(0, u - 0.5) * 2
            frame.shells.append(Frame.Shell(
                head: CGPoint(x: head.x, y: head.y + drop),
                tail: tail.map { CGPoint(x: $0.x, y: $0.y + drop) },
                shadow: CGPoint(x: launch.x + (destination.x - launch.x) * CGFloat(u), y: launch.y + (destination.y - launch.y) * CGFloat(u)),
                shadowOpacity: 0.25 * u,
                shadowRadius: 3 + 6 * CGFloat(descent),
                headScale: Self.headScale(at: u),
                opacity: opacity
            ))
        }
        return frame
    }

    /// Where along the arc (0 the button, 0.5 the apex, 1 the cell) a shell is `elapsed` seconds into
    /// a flight of `flight` seconds (nil while an online shot waits for its landing): the rise over
    /// `Timing.apexHold`, a hold at the apex if the landing is later than a plain flight, then the
    /// descent over the rest of `Timing.shellFlight`, ending at the landing.
    static func progress(elapsed: TimeInterval, flight: TimeInterval?) -> Double {
        let rise = Timing.apexHold
        let fall = max(0.001, Timing.shellFlight - Timing.apexHold)
        guard let flight else {
            return min(0.5, 0.5 * elapsed / max(rise, 0.001))
        }
        guard flight > 0 else { return 1 }
        if flight <= Timing.shellFlight + 0.01 {
            return min(1, max(0, elapsed / flight))
        }
        if elapsed < rise {
            return 0.5 * elapsed / rise
        }
        let descent = flight - fall
        if elapsed > descent {
            return min(1, 0.5 + 0.5 * (elapsed - descent) / fall)
        }
        return 0.5
    }

    /// The arc: a straight line from `from` to `to` lifted by a parabola whose height is 0.35 of the
    /// distance, held to 60…220 points.
    static func point(from: CGPoint, to: CGPoint, at u: Double) -> CGPoint {
        let t = CGFloat(min(1, max(0, u)))
        let distance = hypot(to.x - from.x, to.y - from.y)
        let height = min(220, max(60, distance * 0.35))
        return CGPoint(
            x: from.x + (to.x - from.x) * t,
            y: from.y + (to.y - from.y) * t - 4 * height * t * (1 - t)
        )
    }

    /// The head grows from 0.6 to 1.2 at the apex and shrinks to 0.8 on the descent.
    static func headScale(at u: Double) -> CGFloat {
        let t = CGFloat(min(1, max(0, u)))
        return t < 0.5 ? 0.6 + 0.6 * (t / 0.5) : 1.2 - 0.4 * ((t - 0.5) / 0.5)
    }

    // MARK: Drawing

    // Off the main actor: the Canvas renders asynchronously and the frame carries everything it needs.

    nonisolated static func draw(_ frame: Frame, in context: inout GraphicsContext) {
        for shell in frame.shells {
            // The shadow on the water.
            let radius = shell.shadowRadius
            context.fill(
                Path(ellipseIn: CGRect(x: shell.shadow.x - radius, y: shell.shadow.y - radius * 0.5, width: radius * 2, height: radius)),
                with: .color(Color.black.opacity(shell.shadowOpacity * shell.opacity))
            )

            // The tail, added as light.
            if shell.tail.count > 1 {
                var path = Path()
                path.move(to: shell.tail[0])
                for point in shell.tail.dropFirst() {
                    path.addLine(to: point)
                }
                path.addLine(to: shell.head)
                context.drawLayer { light in
                    light.blendMode = .plusLighter
                    light.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [Theme.flame.opacity(0), Theme.flame.opacity(0.7 * shell.opacity), Theme.ember.opacity(0.95 * shell.opacity)]),
                            startPoint: shell.tail[0],
                            endPoint: shell.head
                        ),
                        style: StrokeStyle(lineWidth: 2 * shell.headScale, lineCap: .round, lineJoin: .round)
                    )
                }
            }

            // The head: a soft halo, then the bright point.
            let headRadius = 2.5 * shell.headScale
            let core = frame.flashes ? Color.white : Theme.ember
            if frame.blurs {
                context.drawLayer { halo in
                    halo.addFilter(.blur(radius: 2))
                    halo.blendMode = .plusLighter
                    halo.fill(circle(shell.head, headRadius * 2.4), with: .color(Theme.flame.opacity(0.6 * shell.opacity)))
                }
            } else {
                context.fill(circle(shell.head, headRadius * 2), with: .color(Theme.flame.opacity(0.35 * shell.opacity)))
            }
            context.fill(circle(shell.head, headRadius), with: .color(core.opacity(shell.opacity)))
        }
    }

    nonisolated private static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}
