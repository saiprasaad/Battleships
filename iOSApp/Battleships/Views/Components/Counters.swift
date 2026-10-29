import SwiftUI

extension View {
    /// A number that rolls to its new value: monospaced digits with a numeric content transition on
    /// `Motion.Curve.counter`. Under the reduced tier the roll is the short fade; in the still tier
    /// the digits simply change.
    func rollingNumber(_ value: Int) -> some View {
        modifier(RollingNumber(value: value))
    }
}

private struct RollingNumber: ViewModifier {
    let value: Int
    @Environment(\.motionPolicy) private var policy

    func body(content: Content) -> some View {
        let rolls = policy.tier != .still
        content
            .monospacedDigit()
            .contentTransition(rolls ? .numericText(value: Double(value)) : .identity)
            .animation(rolls ? Motion.Curve.counter.policy(policy) : nil, value: value)
    }
}

/// "+12" in victory green or "−9" in hit red beside a rating: it floats up 18 pt and fades on
/// `Motion.Curve.float`, again whenever `trigger` changes. Decorative (the rating itself carries
/// the news), so it is hidden from VoiceOver. In the still tier it simply shows, and stays until
/// the caller takes it down.
struct DeltaChip: View {
    let delta: Int
    let trigger: AnyHashable
    @Environment(\.motionPolicy) private var policy
    @State private var isFloating = false

    var body: some View {
        let lift: CGFloat = policy.tier == .full ? 18 : 0
        chip
            .offset(y: isFloating ? -lift : 0)
            .opacity(isFloating ? 0 : 1)
            .onAppear { float() }
            .onChange(of: trigger) { replay() }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var chip: some View {
        Text(label)
            .scaledFont(13, weight: .heavy, design: .rounded, relativeTo: .footnote)
            .monospacedDigit()
            .foregroundStyle(delta >= 0 ? Theme.victory : Theme.hit)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background((delta >= 0 ? Theme.victory : Theme.hit).opacity(0.16), in: Capsule())
    }

    private var label: String {
        delta >= 0 ? "+\(delta)" : "−\(-delta)"
    }

    private func float() {
        guard !policy.holdsStill else { return }
        withAnimation(Motion.Curve.float) {
            isFloating = true
        }
    }

    /// Lands without animating, then floats again on the next turn of the run loop.
    private func replay() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isFloating = false
        }
        Task { @MainActor in
            float()
        }
    }
}
