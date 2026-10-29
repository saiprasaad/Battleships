import SwiftUI

private struct StampPose {
    var scale: CGFloat = 2.4
    var opacity: Double = 0
}

/// The stamp's beats, in seconds: keyframe timings, not `Animation` curves.
private enum StampBeat {
    /// Scale 2.4 → 0.92: the slam.
    static let slam: TimeInterval = 0.18
    /// 0.92 → 1: the rebound, done by 0.43 s.
    static let settle: TimeInterval = 0.25
    /// Opacity 0 → 1.
    static let appear: TimeInterval = 0.08
    /// 1 → 0 at the end.
    static let fade: TimeInterval = 0.3
    /// The lean of the stamp, in degrees.
    static let tilt: Double = -8
}

/// The one rubber stamp in the game: SUNK, slammed over a hull. It plays when it appears and again
/// each time `trigger` changes: scale 2.4 → 0.92 at 0.18 s → 1 by 0.43 s, opacity 0 → 1 in 80 ms,
/// held, then gone over 0.3 s, `holds` seconds after it appeared, leaning −8°. Sized by its frame
/// (give it the cell or the hull: the lettering scales down to fit). Policy-aware: in the still tier
/// it fades in and out at scale 1 with no lean. Hidden from VoiceOver: the announcement carries the word.
struct StampView<Trigger: Equatable>: View {
    let text: String
    var tint: Color = Theme.hit
    let trigger: Trigger
    /// How long the stamp is on screen in all, from its first frame to its last.
    var holds: TimeInterval = Timing.stampHold
    @Environment(\.motionPolicy) private var policy
    /// Bumped on appearance and on every trigger, so the keyframes replay.
    @State private var plays = 0

    var body: some View {
        let isStill = policy.holdsStill
        let hold = max(0.01, holds - StampBeat.appear - StampBeat.fade)
        KeyframeAnimator(initialValue: StampPose(), trigger: plays) { pose in
            label
                .scaleEffect(isStill ? 1 : pose.scale)
                .opacity(pose.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(0.92, duration: StampBeat.slam)
                SpringKeyframe(1, duration: StampBeat.settle, spring: .bouncy)
            }
            KeyframeTrack(\.opacity) {
                LinearKeyframe(1, duration: StampBeat.appear)
                LinearKeyframe(1, duration: hold)
                LinearKeyframe(0, duration: StampBeat.fade)
            }
        }
        .rotationEffect(.degrees(isStill ? 0 : StampBeat.tilt))
        .onAppear { plays += 1 }
        .onChange(of: trigger) { plays += 1 }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var label: some View {
        Text(text)
            .tracking(3)
            .displayFont(18, weight: .black)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tint, lineWidth: 2.5)
            )
            .mask {
                RaggedMask(seed: UInt64(truncatingIfNeeded: text.hashValue))
            }
            .glow(tint, radius: 8)
    }
}

/// The ink of a rubber stamp: solid with flecks missing along its edges and a few holes inside, the
/// same for a seed.
private struct RaggedMask: View {
    let seed: UInt64

    var body: some View {
        Canvas { context, size in
            RaggedMask.draw(seed: seed, size: size, in: context)
        }
    }

    private static func draw(seed: UInt64, size: CGSize, in context: GraphicsContext) {
        let rect = CGRect(origin: .zero, size: size)
        guard rect.width > 0, rect.height > 0 else { return }
        context.fill(Path(roundedRect: rect, cornerRadius: 6, style: .continuous), with: .color(.white))
        var generator = SplitMix64(seed: seed)
        var holes = context
        holes.blendMode = .destinationOut
        // Nicks along the edges.
        for _ in 0..<22 {
            let onVerticalEdge = Bool.random(using: &generator)
            let along = CGFloat.random(in: 0...1, using: &generator)
            let radius = CGFloat.random(in: 0.5...2, using: &generator)
            let point: CGPoint
            if onVerticalEdge {
                let x = Bool.random(using: &generator) ? rect.minX : rect.maxX
                point = CGPoint(x: x + CGFloat.random(in: -0.5...0.5, using: &generator), y: rect.minY + along * rect.height)
            } else {
                let y = Bool.random(using: &generator) ? rect.minY : rect.maxY
                point = CGPoint(x: rect.minX + along * rect.width, y: y + CGFloat.random(in: -0.5...0.5, using: &generator))
            }
            holes.fill(
                Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(.white)
            )
        }
        // A few dry spots inside.
        for _ in 0..<5 {
            let point = CGPoint(
                x: rect.minX + CGFloat.random(in: 0.1...0.9, using: &generator) * rect.width,
                y: rect.minY + CGFloat.random(in: 0.1...0.9, using: &generator) * rect.height
            )
            let radius = CGFloat.random(in: 0.4...1.1, using: &generator)
            holes.fill(
                Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(.white.opacity(0.7))
            )
        }
    }
}
