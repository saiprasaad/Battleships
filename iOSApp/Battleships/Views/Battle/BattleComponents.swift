import BattleshipCore
import SwiftUI

/// The target readout and the Fire button.
struct FireBar: View {
    let aimed: Coordinate?
    let isMyTurn: Bool
    let isSubmitting: Bool
    let canFire: Bool
    let onFire: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(isMyTurn ? "TARGET" : "STAND BY")
                    .tracking(1.6)
                    .scaledFont(11, weight: .heavy, design: .rounded, relativeTo: .caption2)
                    .foregroundStyle(.secondary)
                Text(readout)
                    .displayFont(28, weight: .black, monospacedDigits: true)
                    .foregroundStyle(target == nil ? Color.white.opacity(0.25) : Theme.reticle)
                    .glow(target == nil ? .clear : Theme.reticle, radius: 10)
                    .contentTransition(.numericText())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .animation(.snappy, value: target)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(target.map { "Target \($0.notation)" } ?? (isMyTurn ? "No target" : "Stand by"))
            .accessibilityHint(subtitle)

            Spacer(minLength: 8)

            Button { onFire() } label: {
                if isSubmitting {
                    ProgressView()
                        .tint(.white)
                        .frame(minWidth: 82)
                } else {
                    Label("FIRE", systemImage: "flame.fill")
                }
            }
            .buttonStyle(FireButtonStyle(isArmed: canFire))
            .disabled(!canFire)
            .accessibilityLabel("Fire")
            .accessibilityHint(aimed.map { "Fires at \($0.notation)." } ?? "Aim at a square in enemy waters first.")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 18)
        .hudPanel(cornerRadius: 28)
        // At the very largest text sizes the bar would push the board off screen.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private var target: Coordinate? { isMyTurn ? aimed : nil }

    private var readout: String {
        target?.notation ?? "– –"
    }

    private var subtitle: String {
        guard isMyTurn else { return "The enemy is taking their shot" }
        return aimed == nil ? "Tap a square in enemy waters" : "Tap it again or press Fire"
    }
}

/// Shown under a finished battle.
struct ResultBar: View {
    let didWin: Bool
    let stats: ShotStats
    let onSummary: @MainActor () -> Void
    let onRematch: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility sizes the buttons go under the result, which has no room beside them.
        let isStacked = dynamicTypeSize.isAccessibilitySize
        let layout = isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            summary
            if !isStacked {
                Spacer(minLength: 8)
            }
            buttons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .hudPanel(cornerRadius: 28)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(didWin ? "VICTORY" : "DEFEAT")
                .displayFont(20, weight: .black)
                .foregroundStyle(didWin ? AnyShapeStyle(Theme.goldLeaf) : AnyShapeStyle(Theme.hit))
                .glow(didWin ? Theme.gold : Theme.hit, radius: 8)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(Phrase.count(stats.hits, "hit")) from \(Phrase.count(stats.shotsFired, "shot"))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button("Summary") { onSummary() }
                .buttonStyle(.bordered)
                .tint(.white)
            Button("Rematch") { onRematch() }
                .primaryActionStyle()
                .tint(didWin ? Theme.amber : Theme.hit)
        }
    }
}

/// A transient headline such as "You sank their Cruiser!".
struct AnnouncementBanner: View {
    let announcement: BattleController.Announcement

    var body: some View {
        let tint = announcement.isGoodNews ? Theme.victory : Theme.hit
        HStack(spacing: 10) {
            Image(systemName: announcement.isGoodNews ? "scope" : "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.gradient))
            Text(announcement.message)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
        .padding(.leading, 8)
        .padding(.trailing, 18)
        .padding(.vertical, 8)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color.black.opacity(0.35)))
        }
        .overlay(Capsule().strokeBorder(tint.opacity(0.7), lineWidth: 1))
        .shadow(color: tint.opacity(0.45), radius: 16)
        .accessibilityHidden(true) // Announced to VoiceOver directly.
    }
}

/// A button title that becomes a spinner while its action runs, without changing the button's size.
struct BusyLabel: View {
    let title: String
    let isBusy: Bool

    var body: some View {
        Text(title)
            .opacity(isBusy ? 0 : 1)
            .overlay {
                if isBusy {
                    ProgressView()
                        .tint(.white)
                }
            }
    }
}

/// Centres its content in the space available, and scrolls when the content is taller, as it can
/// be at large text sizes. `onTapOutside` runs for taps beside the content.
struct CenteredScrollView<Content: View>: View {
    private let content: Content
    private let onTapOutside: (@MainActor () -> Void)?

    init(@ViewBuilder content: () -> Content, onTapOutside: (@MainActor () -> Void)? = nil) {
        self.content = content()
        self.onTapOutside = onTapOutside
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    .background {
                        if let onTapOutside {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { onTapOutside() }
                                .accessibilityHidden(true)
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Offered when the opponent has let their time to move run out.
struct ClaimVictoryCard: View {
    let opponentName: String
    let isSubmitting: Bool
    let onClaim: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isStacked = dynamicTypeSize.isAccessibilitySize
        let layout = isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 14))
        layout {
            Image(systemName: "hourglass.bottomhalf.filled")
                .font(.title2)
                .foregroundStyle(Theme.amber)
                .glow(Theme.amber, radius: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(opponentName) is out of time")
                    .font(.headline)
                Text("They haven't fired in days. You can take the win.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !isStacked {
                Spacer(minLength: 8)
            }
            Button { onClaim() } label: {
                BusyLabel(title: "Claim Victory", isBusy: isSubmitting)
            }
            .primaryActionStyle()
            .tint(Theme.amber)
            .disabled(isSubmitting)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel(cornerRadius: 20)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.amber.opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// An incoming challenge, waiting for an answer.
struct ChallengeCard: View {
    let opponentName: String
    let caption: String?
    let mode: GameMode?
    /// An answer is on its way to the server.
    let isSubmitting: Bool
    let onAccept: @MainActor () -> Void
    let onDecline: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        CenteredScrollView {
            VStack(spacing: 18) {
                ZStack {
                    SonarPing(tint: Theme.amber)
                        .frame(width: isLarge ? 110 : 170, height: isLarge ? 110 : 170)
                    OpponentAvatar(name: opponentName, size: isLarge ? 64 : 84)
                        .glow(Theme.amber, radius: 12)
                }
                .frame(height: isLarge ? 100 : 150)
                VStack(spacing: 6) {
                    Text("INCOMING CHALLENGE")
                        .tracking(2)
                        .scaledFont(12, weight: .heavy, design: .rounded, relativeTo: .caption)
                        .foregroundStyle(Theme.amber)
                    Text("\(opponentName) challenges you!")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    if let caption {
                        Text(caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let mode {
                    Label {
                        Text("\(mode.displayName): \(mode.tagline)")
                    } icon: {
                        Image(systemName: "square.grid.3x3.fill")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                let buttons = isLarge ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                buttons {
                    Button(role: .destructive) { onDecline() } label: {
                        BusyLabel(title: "Decline", isBusy: isSubmitting)
                    }
                    .buttonStyle(.bordered)
                    Button("Accept & Deploy") { onAccept() }
                        .primaryActionStyle()
                        .tint(Theme.hit)
                }
                .controlSize(.large)
                .disabled(isSubmitting)
            }
            .padding(28)
            .frame(maxWidth: 440)
            .hudPanel(cornerRadius: 30)
            .padding()
        }
    }
}

/// Matchmaking, or a challenge the other player hasn't answered yet.
struct WaitingCard: View {
    let isMatchmaking: Bool
    let opponentName: String
    let mode: GameMode?
    /// The withdrawal is on its way to the server.
    let isSubmitting: Bool
    let onCancel: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        CenteredScrollView {
            VStack(spacing: 18) {
                Group {
                    if isMatchmaking {
                        RadarScope()
                    } else {
                        ZStack {
                            SonarPing()
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: isLarge ? 34 : 46))
                                .foregroundStyle(Theme.reticle)
                                .glow(Theme.reticle, radius: 10)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(width: isLarge ? 110 : 170, height: isLarge ? 110 : 170)
                Text(isMatchmaking ? "Searching for an Opponent" : "Challenge Sent")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) { onCancel() } label: {
                    BusyLabel(title: isMatchmaking ? "Stop Searching" : "Withdraw Challenge", isBusy: isSubmitting)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isSubmitting)
            }
            .padding(28)
            .frame(maxWidth: 440)
            .hudPanel(cornerRadius: 30)
            .padding()
        }
    }

    private var message: String {
        if isMatchmaking {
            let rules = mode.map { " \($0.displayName)" } ?? ""
            return "You'll be paired with the next captain looking for a\(rules) battle. We'll notify you when the fight is on."
        }
        return "Waiting for \(opponentName) to accept. We'll notify you when they do."
    }
}
