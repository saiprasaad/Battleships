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
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)
                Text(readout)
                    .font(.display(28, weight: .black).monospacedDigit())
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

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(didWin ? "VICTORY" : "DEFEAT")
                    .font(.display(20, weight: .black))
                    .foregroundStyle(didWin ? AnyShapeStyle(Theme.goldLeaf) : AnyShapeStyle(Theme.hit))
                    .glow(didWin ? Theme.gold : Theme.hit, radius: 8)
                Text("\(stats.hits) hits from \(stats.shotsFired) shots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Summary") { onSummary() }
                .buttonStyle(.bordered)
                .tint(.white)
            Button("Rematch") { onRematch() }
                .primaryActionStyle()
                .tint(didWin ? Theme.amber : Theme.hit)
        }
        .padding(14)
        .hudPanel(cornerRadius: 28)
        .padding(.horizontal)
        .padding(.bottom, 6)
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

/// Offered when the opponent has let their time to move run out.
struct ClaimVictoryCard: View {
    let opponentName: String
    let onClaim: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 14) {
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
            Spacer(minLength: 8)
            Button("Claim Victory") { onClaim() }
                .primaryActionStyle()
                .tint(Theme.amber)
        }
        .padding(14)
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
    let onAccept: @MainActor () -> Void
    let onDecline: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                SonarPing(tint: Theme.amber)
                    .frame(width: 170, height: 170)
                OpponentAvatar(name: opponentName, size: 84)
                    .glow(Theme.amber, radius: 12)
            }
            .frame(height: 150)
            VStack(spacing: 6) {
                Text("INCOMING CHALLENGE")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .tracking(2)
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
            HStack(spacing: 12) {
                Button("Decline", role: .destructive) { onDecline() }
                    .buttonStyle(.bordered)
                Button("Accept & Deploy") { onAccept() }
                    .primaryActionStyle()
                    .tint(Theme.hit)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: 440)
        .hudPanel(cornerRadius: 30)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Matchmaking, or a challenge the other player hasn't answered yet.
struct WaitingCard: View {
    let isMatchmaking: Bool
    let opponentName: String
    let mode: GameMode?
    let onCancel: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Group {
                if isMatchmaking {
                    RadarScope()
                } else {
                    ZStack {
                        SonarPing()
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(Theme.reticle)
                            .glow(Theme.reticle, radius: 10)
                    }
                }
            }
            .frame(width: 170, height: 170)
            Text(isMatchmaking ? "Searching for an Opponent" : "Challenge Sent")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(isMatchmaking ? "Stop Searching" : "Withdraw Challenge", role: .destructive) { onCancel() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: 440)
        .hudPanel(cornerRadius: 30)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var message: String {
        if isMatchmaking {
            let rules = mode.map { " \($0.displayName)" } ?? ""
            return "You'll be paired with the next captain looking for a\(rules) battle. We'll notify you when the fight is on."
        }
        return "Waiting for \(opponentName) to accept. We'll notify you when they do."
    }
}
