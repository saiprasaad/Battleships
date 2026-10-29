import SwiftUI

/// The press for a screen's main actions: a capsule with depth that sinks under the finger (scale
/// 0.96, 2 pt down, its shadow drawing in from 14 to 6) on `Motion.Curve.press` and springs back on
/// `Motion.Curve.release`. Under the reduced and still tiers it only dims. `tint` fills it;
/// `isProminent: false` is the translucent secondary look (`SecondaryButtonStyle`).
struct DepthButtonStyle: ButtonStyle {
    var tint: Color = Theme.reticle
    var isProminent = true
    /// Fill with the view hierarchy's `.tint(_:)` instead of `tint`, which is how `primaryActionStyle()`
    /// keeps honouring the tints its callers set.
    var followsViewTint = false

    func makeBody(configuration: Configuration) -> some View {
        DepthButtonFace(
            label: configuration.label,
            isPressed: configuration.isPressed,
            tint: tint,
            isProminent: isProminent,
            followsViewTint: followsViewTint
        )
    }
}

/// The translucent companion to `DepthButtonStyle`: the same press on a glassy face.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DepthButtonFace(
            label: configuration.label,
            isPressed: configuration.isPressed,
            tint: Theme.reticle,
            isProminent: false,
            followsViewTint: false
        )
    }
}

/// The face of both styles. A view of its own so the environment (policy, enabled, control size)
/// is read where SwiftUI installs it.
private struct DepthButtonFace<ButtonLabel: View>: View {
    let label: ButtonLabel
    let isPressed: Bool
    let tint: Color
    let isProminent: Bool
    let followsViewTint: Bool
    @Environment(\.motionPolicy) private var policy
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        let moves = policy.tier == .full
        let sinks = moves && isPressed
        label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, insets.vertical)
            .padding(.horizontal, insets.horizontal)
            .background { face }
            .overlay(Capsule().strokeBorder(.white.opacity(isProminent ? 0.35 : 0.18), lineWidth: 1))
            .shadow(color: shadowColor, radius: sinks ? 6 : 14, y: sinks ? 3 : 8)
            .scaleEffect(sinks ? 0.96 : 1)
            .offset(y: sinks ? 2 : 0)
            .opacity(isEnabled ? (!moves && isPressed ? 0.7 : 1) : 0.45)
            .saturation(isEnabled ? 1 : 0.3)
            .animation(pressAnimation, value: isPressed)
    }

    @ViewBuilder
    private var face: some View {
        if isProminent {
            Capsule()
                .fill(fill)
                .overlay(
                    Capsule()
                        .fill(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center))
                        .padding(1.5)
                )
        } else {
            Capsule()
                .fill(.white.opacity(0.1))
        }
    }

    private var fill: AnyShapeStyle {
        followsViewTint ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(tint)
    }

    private var shadowColor: Color {
        guard isEnabled else { return .clear }
        if !isProminent { return .black.opacity(0.25) }
        return followsViewTint ? .black.opacity(0.35) : tint.opacity(0.55)
    }

    private var pressAnimation: Animation {
        guard policy.tier == .full else { return Motion.Curve.reduced }
        return isPressed ? Motion.Curve.press : Motion.Curve.release
    }

    /// Padding by control size, matching the heights of the system's bordered buttons.
    private var insets: (vertical: CGFloat, horizontal: CGFloat) {
        switch controlSize {
        case .mini: (vertical: 5, horizontal: 10)
        case .small: (vertical: 7, horizontal: 13)
        case .large: (vertical: 14, horizontal: 22)
        case .extraLarge: (vertical: 17, horizontal: 26)
        default: (vertical: 10, horizontal: 17)
        }
    }
}

extension View {
    /// One recoil for every button: a quick kick to `kick` and a jolt downwards, a rebound and a
    /// springy settle, replayed whenever `trigger` changes. 1.12 is the Fire button, 1.06 Start
    /// Battle, Rematch and Set Sail, 1.0 an offset-only jolt. Nothing moves below the full tier.
    func recoil(on trigger: some Equatable, kick: CGFloat = 1.06) -> some View {
        modifier(Recoil(trigger: trigger, kick: kick))
    }

    /// A single pulse to `scale` and back whenever `trigger` changes, for a chip or a counter that
    /// just changed. Nothing moves below the full tier.
    func pulse(on trigger: some Equatable, scale: CGFloat = 1.15) -> some View {
        modifier(Pulse(trigger: trigger, scale: scale))
    }
}

private struct RecoilPose {
    var scale: CGFloat = 1
    var dy: CGFloat = 0
}

/// The recoil's beats, in seconds: keyframe timings, not `Animation` curves, so they live here
/// beside the one modifier that plays them.
private enum RecoilBeat {
    static let kick: TimeInterval = 0.04
    static let rebound: TimeInterval = 0.12
    static let settle: TimeInterval = 0.16
    static let recover: TimeInterval = 0.28
}

private enum PulseBeat {
    static let rise: TimeInterval = 0.12
    static let settle: TimeInterval = 0.30
}

private struct Recoil<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    let kick: CGFloat
    @Environment(\.motionPolicy) private var policy

    func body(content: Content) -> some View {
        let moves = policy.tier == .full
        let peak: CGFloat = moves ? kick : 1
        // 3 pt down for the Fire button's 1.12; a plain 2 pt jolt for a kick of 1.
        let jolt: CGFloat = peak > 1 ? 3 * (peak - 1) / 0.12 : (moves ? 2 : 0)
        KeyframeAnimator(initialValue: RecoilPose(), trigger: trigger) { pose in
            content
                .scaleEffect(pose.scale)
                .offset(y: pose.dy)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                LinearKeyframe(peak, duration: RecoilBeat.kick)
                CubicKeyframe(1 - (peak - 1) * 0.6, duration: RecoilBeat.rebound)
                SpringKeyframe(1, duration: RecoilBeat.settle, spring: .bouncy)
            }
            KeyframeTrack(\.dy) {
                LinearKeyframe(jolt, duration: RecoilBeat.kick)
                SpringKeyframe(0, duration: RecoilBeat.recover)
            }
        }
    }
}

private struct Pulse<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    let scale: CGFloat
    @Environment(\.motionPolicy) private var policy

    func body(content: Content) -> some View {
        let peak = policy.tier == .full ? scale : 1
        KeyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { value in
            content.scaleEffect(value)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(peak, duration: PulseBeat.rise)
                SpringKeyframe(1, duration: PulseBeat.settle, spring: .bouncy)
            }
        }
    }
}
