import SwiftUI

/// The callouts' beats: keyframe lengths that live beside the views that play them.
private enum CalloutBeat {
    /// The streak chip pops in this long after the banner's text.
    static let chipDelay: TimeInterval = 0.12
    /// The coach mark's finger bounces this often, this many times, then rests.
    static let bounceGap: TimeInterval = 1.6
    static let bounces = 3
}

/// A headline that stands in for whose turn it is, held for `Timing.calloutHold` (BAT-12).
enum BattleCallout: Equatable, Sendable {
    /// The enemy has one ship left (`isMine == false`), or the player does.
    case lastShip(isMine: Bool)

    var headline: String {
        switch self {
        case let .lastShip(isMine): isMine ? "Last ship standing" : "Last ship"
        }
    }

    var tint: Color {
        switch self {
        case let .lastShip(isMine): isMine ? Theme.hit : Theme.gold
        }
    }

    /// What VoiceOver hears, as a `.game` announcement.
    var announcement: String {
        switch self {
        case let .lastShip(isMine): isMine ? "Last ship standing." : "Last ship."
        }
    }
}

/// "×3" at the corner of the battle banner when a hit extends a run: it pops in `CalloutBeat.chipDelay`
/// after the text on `Motion.Curve.snap`; below the full tier it fades in place.
struct StreakChip: View {
    let count: Int
    @Environment(\.motionPolicy) private var policy
    @State private var isShown = false

    var body: some View {
        Text("×\(count)")
            .scaledFont(12, weight: .black, design: .rounded, relativeTo: .caption)
            .monospacedDigit()
            .foregroundStyle(Theme.abyss)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.ember, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 1))
            .shadow(color: Theme.flame.opacity(0.6), radius: 6)
            .scaleEffect(isShown || policy.tier != .full ? 1 : 0.3)
            .opacity(isShown ? 1 : 0)
            .onAppear {
                let animation = policy.tier == .full ? Motion.Curve.snap.delay(CalloutBeat.chipDelay) : Motion.Curve.reduced
                withAnimation(animation) {
                    isShown = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// The first battle's one hint: a capsule between the HUD and the board, pointing down at the
/// water, with a finger that bounces a few times. It fades on the first aim and is never shown
/// again (BAT-15). No letterbox, no spotlight, no demo.
struct CoachMark: View {
    nonisolated static let defaultText = "Tap a square to aim. Tap it again, or press Fire."

    var text = CoachMark.defaultText
    @Environment(\.motionPolicy) private var policy
    @State private var bounces = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.reticle)
                .symbolEffect(.bounce, value: bounces)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background {
            Capsule()
                .fill(Theme.abyss.opacity(0.85))
                .overlay(Capsule().strokeBorder(Theme.reticle.opacity(0.55), lineWidth: 1))
        }
        .overlay(alignment: .bottom) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.caption2)
                .foregroundStyle(Theme.abyss.opacity(0.85))
                .offset(y: 7)
                .accessibilityHidden(true)
        }
        .shadow(color: Theme.reticle.opacity(0.25), radius: 10)
        .accessibilityElement(children: .combine)
        .task {
            guard policy.tier == .full else { return }
            for _ in 0..<CalloutBeat.bounces {
                try? await Task.sleep(for: .seconds(CalloutBeat.bounceGap))
                guard !Task.isCancelled else { return }
                bounces += 1
            }
        }
    }
}

/// "WHILE YOU WERE AWAY · Tap to skip" over the battle while the opponent's shots replay (BAT-13).
struct ReplayCaption: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption.weight(.bold))
                .accessibilityHidden(true)
            Text("WHILE YOU WERE AWAY")
                .tracking(1.4)
                .scaledFont(11, weight: .heavy, design: .rounded, relativeTo: .caption2)
            Text("·")
                .foregroundStyle(.secondary)
            Text("Tap to skip")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(Theme.amber)
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background {
            Capsule()
                .fill(Theme.abyss.opacity(0.85))
                .overlay(Capsule().strokeBorder(Theme.amber.opacity(0.55), lineWidth: 1))
        }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}
