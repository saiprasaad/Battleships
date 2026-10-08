import BattleshipCore
import SwiftUI

/// Whose turn it is and how both fleets are holding up.
struct BattleHeader: View {
    let perspective: BattlePerspective
    let statusLine: String
    let isMyTurn: Bool
    let isWaiting: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(indicatorColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: isWaiting)
                Text(statusLine)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom) {
                FleetTally(
                    title: "Your fleet",
                    total: perspective.myFleet.count,
                    afloat: perspective.myShipsRemaining,
                    tint: Theme.hull
                )
                Spacer()
                FleetTally(
                    title: "Enemy fleet",
                    total: perspective.rules.fleet.count,
                    afloat: perspective.enemyShipsRemaining,
                    tint: Theme.hit
                )
            }
        }
        .padding()
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var indicatorColor: Color {
        if perspective.isFinished {
            return perspective.didWin == true ? Theme.victory : Theme.hit
        }
        return isMyTurn ? Theme.victory : .orange
    }
}

/// The aim readout and the Fire button.
struct FireBar: View {
    let aimed: Coordinate?
    let isMyTurn: Bool
    let isSubmitting: Bool
    let canFire: Bool
    let onFire: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .contentTransition(.numericText())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .animation(.snappy, value: aimed)
            Spacer(minLength: 8)
            Button { onFire() } label: {
                if isSubmitting {
                    ProgressView()
                        .tint(.white)
                        .frame(minWidth: 60)
                } else {
                    Label("Fire", systemImage: "flame.fill")
                }
            }
            .buttonStyle(FireButtonStyle())
            .disabled(!canFire)
            .accessibilityHint(aimed.map { "Fires at \($0.notation)." } ?? "Aim at a square in enemy waters first.")
        }
        .padding(14)
        .floatingSurface()
        .padding(.horizontal)
        .padding(.bottom, 6)
        .environment(\.colorScheme, .dark)
    }

    private var title: String {
        guard isMyTurn else { return "Stand by" }
        return aimed.map { "Target \($0.notation)" } ?? "Choose a target"
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
                Text(didWin ? "Victory" : "Defeat")
                    .font(.headline)
                    .foregroundStyle(didWin ? Theme.victory : Theme.hit)
                Text("\(stats.hits) hits from \(stats.shotsFired) shots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Summary") { onSummary() }
                .buttonStyle(.bordered)
            Button("Rematch") { onRematch() }
                .primaryActionStyle()
        }
        .padding(14)
        .floatingSurface()
        .padding(.horizontal)
        .padding(.bottom, 6)
        .environment(\.colorScheme, .dark)
    }
}

/// A transient headline such as "You sank their Cruiser!".
struct AnnouncementBanner: View {
    let announcement: BattleController.Announcement

    var body: some View {
        Label {
            Text(announcement.message)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: announcement.isGoodNews ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                .foregroundStyle(announcement.isGoodNews ? Theme.victory : Theme.hit)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .floatingSurface(cornerRadius: 20)
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
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
                .foregroundStyle(.orange)
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
                .tint(.orange)
        }
        .padding(14)
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            OpponentAvatar(name: opponentName, size: 76)
            VStack(spacing: 6) {
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
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: 440)
        .floatingSurface(cornerRadius: 28)
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
            Image(systemName: isMatchmaking ? "dot.radiowaves.left.and.right" : "paperplane.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.reticle)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isMatchmaking)
            Text(isMatchmaking ? "Searching for an Opponent" : "Challenge Sent")
                .font(.title2.weight(.bold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(isMatchmaking ? "Stop Searching" : "Withdraw Challenge", role: .destructive) { onCancel() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: 440)
        .floatingSurface(cornerRadius: 28)
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

/// The end-of-battle card.
struct GameOverOverlay: View {
    let didWin: Bool
    let reason: Outcome.Reason?
    let opponentName: String
    let stats: ShotStats
    let celebrates: Bool
    let onRematch: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
                .accessibilityHidden(true)

            if celebrates {
                ConfettiView()
            }

            VStack(spacing: 18) {
                Image(systemName: didWin ? "trophy.fill" : "water.waves")
                    .font(.system(size: 60))
                    .foregroundStyle(didWin ? Color.yellow : Theme.reticle)
                    .symbolEffect(.bounce, value: didWin)
                Text(didWin ? "Victory!" : "Defeat")
                    .font(.largeTitle.weight(.heavy))
                Text(subtitle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack {
                    StatTile(title: "Shots", value: "\(stats.shotsFired)")
                    StatTile(title: "Hits", value: "\(stats.hits)")
                    StatTile(title: "Accuracy", value: stats.accuracy.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                }
                .padding(.vertical, 6)
                VStack(spacing: 10) {
                    Button { onRematch() } label: {
                        Label("Rematch", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .primaryActionStyle()
                    Button("View the Board") { onClose() }
                        .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
            .padding(28)
            .frame(maxWidth: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .padding()
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }

    private var subtitle: String {
        switch (didWin, reason) {
        case (true, .resignation): "\(opponentName) struck their colours."
        case (true, .timeout): "\(opponentName) ran out of time to move."
        case (true, _): "You sent the enemy fleet to the bottom."
        case (false, .resignation): "You resigned. There's always the next battle."
        case (false, .timeout): "You ran out of time to make your move."
        case (false, _): "\(opponentName) sank your entire fleet."
        }
    }
}

/// Falling paper, for victories.
struct ConfettiView: View {
    private struct Piece {
        let x: CGFloat
        let delay: Double
        let speed: Double
        let sway: Double
        let spin: Double
        let size: CGFloat
        let color: Color
    }

    @State private var start = Date()
    @State private var pieces = ConfettiView.makePieces()

    private nonisolated static func makePieces() -> [Piece] {
        (0..<90).map { _ in
            Piece(
                x: .random(in: 0...1),
                delay: .random(in: 0...1.2),
                speed: .random(in: 0.18...0.32),
                sway: .random(in: 1.5...3.5),
                spin: .random(in: 2...7),
                size: .random(in: 7...13),
                color: [Color.yellow, .orange, .pink, Theme.reticle, Theme.victory, .white].randomElement()!
            )
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                for piece in pieces {
                    let age = elapsed - piece.delay
                    guard age > 0 else { continue }
                    let y = -20 + age * piece.speed * size.height
                    guard y < size.height + 20 else { continue }
                    let x = piece.x * size.width + sin(age * piece.sway) * 24
                    var copy = context
                    copy.translateBy(x: x, y: y)
                    copy.rotate(by: .radians(age * piece.spin))
                    let rect = CGRect(x: -piece.size / 2, y: -piece.size / 4, width: piece.size, height: piece.size / 2)
                    copy.fill(Path(rect), with: .color(piece.color))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
