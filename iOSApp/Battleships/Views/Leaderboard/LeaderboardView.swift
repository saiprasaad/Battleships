import BattleshipAPI
import SwiftUI

/// The top captains by rating: the first three on a podium that rises step by step, the rest
/// cascading in below. Ratings roll when they change, and on a refresh movers slide past each other.
struct LeaderboardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.motionPolicy) private var policy
    @State private var entries: [LeaderboardEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showsSignIn = false
    @State private var moderation: ModerationRequest?
    /// The player's rank the last time the rankings arrived, to say when it changes.
    @State private var yourRank: Int?

    /// Rows past this many enter together, so a long list still settles in well under a second.
    private static let cascadeCap = 8

    /// The player's own row lights up once the cascade has settled.
    private static var tintDelay: TimeInterval {
        Timing.Stagger.row * Double(cascadeCap) + PodiumBeat.rise
    }

    /// What the screen shows: signed out, the loader, a failure, an empty board or the rankings.
    private enum Phase: Equatable {
        case signedOut, loading, failed, empty, ranked
    }

    private var phase: Phase {
        if !app.isSignedIn { return .signedOut }
        if !entries.isEmpty { return .ranked }
        if isLoading { return .loading }
        if errorMessage != nil { return .failed }
        return .empty
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .signedOut:
                    EmptySeaView(title: "Sign In to See Rankings", message: "Win online battles to climb the leaderboard.") {
                        Button("Sign In") {
                            app.feedback.play(.navigate)
                            showsSignIn = true
                        }
                        .primaryActionStyle()
                    }
                    .staggeredEntrance(index: 0, trigger: app.isSignedIn)
                case .loading:
                    SonarLoader(captions: ["Scanning the horizon…", "Hailing the fleet…"])
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                case .failed:
                    EmptySeaView(title: "Leaderboard Unavailable", message: errorMessage ?? "") {
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                case .empty:
                    VStack(spacing: 20) {
                        EmptyPodium()
                        EmptySeaView(title: "No Rankings Yet", message: "Finish an online battle to get on the board.")
                    }
                case .ranked:
                    rankings
                }
            }
            // The loader shrinks and fades as the rankings perform their entrance: no cut.
            .animation(Motion.Curve.state.policy(policy), value: phase)
            .scrollContentBackground(.hidden)
            .background { OceanBackdrop() }
            .navigationTitle("Leaderboard")
            .refreshable { await load() }
            .task(id: app.session.account?.id) { await load() }
            .sheet(isPresented: $showsSignIn) { AuthSheet() }
            .playerModeration($moderation)
        }
    }

    private var rankings: some View {
        let yourID = app.session.account?.id
        let top = Array(entries.prefix(3))
        let rest = entries.count >= 3 ? Array(entries.dropFirst(3)) : entries
        return List {
            if top.count == 3 {
                Podium(entries: top, yourID: yourID, moderation: $moderation)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(rest.enumerated()), id: \.element.id) { index, entry in
                let isYou = entry.player.id == yourID
                LeaderboardRow(entry: entry, isYou: isYou, tintDelay: Self.tintDelay)
                    .playerContextMenu(isYou ? nil : entry.player, request: $moderation)
                    .staggeredEntrance(index: index, trigger: 0, cap: Self.cascadeCap)
            }
        }
        .listStyle(.plain)
        // Movers slide past each other on a refresh; there is no row-to-podium morph.
        .animation(Motion.Curve.list.policy(policy), value: entries)
    }

    private func load() async {
        guard app.isSignedIn else {
            entries = []
            yourRank = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await app.api.leaderboard()
            entries = fresh
            errorMessage = nil
            noteRank(in: fresh)
        } catch is CancellationError {
        } catch {
            if entries.isEmpty {
                errorMessage = error.userMessage
            } else {
                // The rankings stay up; the failure is news at the top.
                ToastCenter.shared.show(.error, "Couldn't refresh the leaderboard. \(error.userMessage)")
                app.feedback.play(.toastError)
            }
        }
    }

    /// "You are now rank 7", once, after a refresh that moved the player.
    private func noteRank(in entries: [LeaderboardEntry]) {
        let rank = entries.first { $0.player.id == app.session.account?.id }?.rank
        defer { yourRank = rank }
        guard let rank, let known = yourRank, rank != known else { return }
        AccessibilityNotification.Announcement("You are now rank \(rank)").post()
    }
}

/// The podium's beats, in seconds: a step's rise (the span of `Motion.Curve.enter`), the lag before
/// an avatar drops onto its landed step, the drop itself (the span of `Motion.Curve.drop`), the
/// crown's spin, its bloom and the sheen across the player's own step.
private enum PodiumBeat {
    static let rise: TimeInterval = 0.55
    static let avatarLag: TimeInterval = 0.08
    static let drop: TimeInterval = 0.22
    static let crown: TimeInterval = 0.45
    static let bloom: TimeInterval = 0.6
    static let sheen: TimeInterval = 0.5
}

private struct LeaderboardRow: View {
    let entry: LeaderboardEntry
    let isYou: Bool
    /// How long the player's own tint waits before fading in: after the cascade.
    let tintDelay: TimeInterval
    @Environment(\.motionPolicy) private var policy
    @State private var showsTint = false

    var body: some View {
        HStack(spacing: 14) {
            rank
                .frame(width: 34)
            OpponentAvatar(name: entry.player.username, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(isYou ? "\(entry.player.username) (you)" : entry.player.username)
                    .font(.headline)
                Text("\(entry.wins)W · \(entry.losses)L")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(entry.player.rating)")
                .font(.title3.weight(.semibold).monospacedDigit())
                .rollingNumber(entry.player.rating)
        }
        .padding(.vertical, 4)
        .listRowBackground(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rank \(entry.rank), \(entry.player.username)\(isYou ? ", you" : ""), rating \(entry.player.rating), \(entry.wins) wins, \(entry.losses) losses")
        .onAppear { showsTint = true }
    }

    /// The player's own row lights up last, once the cascade has settled.
    private var tint: some View {
        Rectangle()
            .fill(Theme.reticle.opacity(0.14))
            .opacity(isYou && showsTint ? 1 : 0)
            .animation(Motion.Curve.fade.policy(policy).delay(policy.tier == .full ? tintDelay : 0), value: showsTint)
    }

    @ViewBuilder
    private var rank: some View {
        switch entry.rank {
        case 1: medal(.yellow)
        case 2: medal(Color(white: 0.75))
        case 3: medal(.orange)
        default:
            Text("\(entry.rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func medal(_ color: Color) -> some View {
        Image(systemName: "medal.fill")
            .font(.title2)
            .foregroundStyle(color)
    }
}

/// The top three on the winners' steps. The steps rise from nothing in the order bronze (right),
/// silver (left), gold (centre) on one cue sheet, their numerals rolling up as they rise; each avatar
/// drops onto its step once it has landed; the crown spins in over the gold avatar with a bloom of
/// light; the player's own step gets a reticle sheen. Tap it to skip to the end. Under VoiceOver and
/// in the still tier the sheet lands at once, finished.
private struct Podium: View {
    /// The top three, in rank order.
    let entries: [LeaderboardEntry]
    let yourID: UUID?
    @Binding var moderation: ModerationRequest?
    @State private var isSkipped = false

    /// Bronze first, then silver, then gold, `Timing.Stagger.surfacing` apart; each avatar drops
    /// `PodiumBeat.avatarLag` after its step has landed; the crown, its bloom and the sheen follow
    /// the gold avatar.
    private static let reveal: CueSheet = {
        var cues: [Cue] = []
        for (order, name) in ["bronze", "silver", "gold"].enumerated() {
            let start = Double(order) * Timing.Stagger.surfacing
            cues.append(Cue(name: name, start: start, duration: PodiumBeat.rise))
            cues.append(Cue(name: "\(name)-avatar", start: start + PodiumBeat.rise + PodiumBeat.avatarLag, duration: PodiumBeat.drop))
        }
        let crownStart = 2 * Timing.Stagger.surfacing + PodiumBeat.rise + PodiumBeat.avatarLag + PodiumBeat.drop
        cues.append(Cue(name: "crown", start: crownStart, duration: PodiumBeat.crown))
        cues.append(Cue(name: "bloom", start: crownStart, duration: PodiumBeat.bloom))
        cues.append(Cue(name: "sheen", start: crownStart, duration: PodiumBeat.sheen))
        return CueSheet(cues)
    }()

    var body: some View {
        CuePlayer(sheet: Self.reveal, trigger: entries.count, isSkipped: isSkipped, onFinished: { isSkipped = false }) { frame in
            HStack(alignment: .bottom, spacing: 10) {
                step(entries[1], cue: "silver", height: 74, color: Color(white: 0.8), frame: frame)
                step(entries[0], cue: "gold", height: 104, color: Theme.gold, frame: frame)
                step(entries[2], cue: "bronze", height: 56, color: Color(red: 0.86, green: 0.55, blue: 0.32), frame: frame)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture { isSkipped = true }
        .accessibilityElement(children: .contain)
    }

    private func step(_ entry: LeaderboardEntry, cue: String, height: CGFloat, color: Color, frame: CueSheet.Frame) -> some View {
        let isYou = entry.player.id == yourID
        let isGold = cue == "gold"
        let rise = frame.progress(cue)
        let drop = frame.progress("\(cue)-avatar")
        let shownRank = frame.hasStarted(cue) ? entry.rank : 0
        return VStack(spacing: 6) {
            if isGold {
                crown(frame: frame)
            }
            OpponentAvatar(name: entry.player.username, size: isGold ? 64 : 52)
                .overlay(Circle().strokeBorder(color, lineWidth: 2.5).padding(-4))
                .glow(color, radius: 8)
                .offset(y: -24 * (1 - drop))
                .opacity(drop)
            Text(isYou ? "You" : entry.player.username)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .opacity(drop)
            Text("\(entry.player.rating)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .rollingNumber(entry.player.rating)
                .opacity(drop)
            ZStack(alignment: .top) {
                stepFace(color: color, isYou: isYou)
                Text("\(shownRank)")
                    .displayFont(26, weight: .black)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, 8)
                    .rollingNumber(shownRank)
                if isYou {
                    sheen(frame: frame)
                }
            }
            .frame(height: max(0, height * rise), alignment: .top)
            .clipped()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .playerContextMenu(isYou ? nil : entry.player, request: $moderation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rank \(entry.rank), \(entry.player.username)\(isYou ? ", you" : ""), rating \(entry.player.rating)")
    }

    private func stepFace(color: Color, isYou: Bool) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [color.opacity(0.55), color.opacity(0.08)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.stroke(isYou ? Theme.reticle.opacity(0.8) : color.opacity(0.5), lineWidth: isYou ? 1.5 : 1))
    }

    /// The crown spins in from −30° over the gold avatar, its glow blooming 8 → 18 → 8.
    private func crown(frame: CueSheet.Frame) -> some View {
        let spin = frame.progress("crown")
        let bloom = frame.progress("bloom", curve: Easing.linear)
        return Image(systemName: "crown.fill")
            .font(.title3)
            .foregroundStyle(Theme.goldLeaf)
            .glow(Theme.gold, radius: 8 + 10 * sin(.pi * bloom))
            .rotationEffect(.degrees(-30 * (1 - spin)))
            .opacity(spin)
            .accessibilityHidden(true)
    }

    /// A reticle highlight sweeping once across the player's own step.
    private func sheen(frame: CueSheet.Frame) -> some View {
        let sweep = frame.progress("sheen", curve: Easing.easeInOut)
        return GeometryReader { proxy in
            LinearGradient(colors: [.clear, Theme.reticle.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: proxy.size.width * 0.6)
                .offset(x: (sweep * 1.6 - 0.6) * proxy.size.width)
        }
        .opacity(frame.isActive("sheen") ? 1 : 0)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The three steps as dotted outlines with "?" avatars brightening in turn: nobody is on the
/// board yet. One ambient loop, held still when the policy says so.
private struct EmptyPodium: View {
    var body: some View {
        LoopClock(loop: .ambient) { seconds in
            HStack(alignment: .bottom, spacing: 10) {
                outline(height: 74, turn: 1, seconds: seconds)
                outline(height: 104, turn: 0, seconds: seconds)
                outline(height: 56, turn: 2, seconds: seconds)
            }
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func outline(height: CGFloat, turn: Double, seconds: Double?) -> some View {
        // Each "?" brightens in its turn around a 2.4 s loop; a soft middle glow when the clock holds.
        let glow: Double = seconds.map { 0.5 + 0.5 * cos(2 * .pi * ($0 / 2.4) - turn * 2 * .pi / 3) } ?? 0.6
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                Text("?")
                    .font(.title3.weight(.bold))
            }
            .foregroundStyle(Theme.reticle.opacity(0.35 + 0.5 * glow))
            .frame(width: 52, height: 52)
            UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                .foregroundStyle(.white.opacity(0.35))
                .frame(height: height)
        }
        .frame(maxWidth: .infinity)
    }
}
