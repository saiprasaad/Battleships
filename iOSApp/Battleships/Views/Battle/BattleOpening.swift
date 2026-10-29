import BattleshipAPI
import BattleshipCore
import SwiftUI

/// BATTLE STATIONS, and Match Found before it for an online opponent who has just appeared (OPN-2).
/// Laid over the battle while `controller.opening` is set: one `CuePlayer` per act, the VS card, the
/// title card, one fast red sweep over the enemy's waters with three contacts, the bezel lighting
/// cyan; a tap anywhere skips. The home surface's sail-in belongs to the boards; the headline lights
/// in the HUD, cued from here at 1.3 s. The Fire bar arms by itself when the controller ends the
/// opening at 1.5 s.
struct BattleOpening: View {
    let controller: BattleController
    /// The enemy board's frame in this view's space, for the sweep and the bezel; nil draws neither.
    var targetBoard: CGRect? = nil
    /// Runs at the 1.3 s cue: the HUD lights its headline letter by letter.
    var onHeadlineCue: @MainActor () -> Void = {}

    @Environment(AppModel.self) private var app: AppModel?
    @Environment(\.motionPolicy) private var policy
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isSkipped = false

    /// Match Found: the scrim and card land, the avatars slide in from the sides, the ratings follow.
    static let matchFoundSheet = CueSheet([
        Cue(name: "scrim", start: 0, duration: 0.4),
        Cue(name: "ping", start: 0),
        Cue(name: "caption", start: 0.1, duration: 0.3),
        Cue(name: "avatars", start: 0.2, duration: 0.5),
        Cue(name: "ratings", start: 0.6, duration: 0.3),
    ], total: Timing.matchFound)

    /// BATTLE STATIONS: the red sweep from 0.6, the title slamming in at 0.7, the bezel at 1.1, the
    /// headline at 1.3; the board accepts taps when the controller ends the opening at 1.5.
    static let openingSheet = CueSheet([
        Cue(name: "sweep", start: 0.6, duration: sweepPeriod),
        Cue(name: "slam", start: 0.7),
        Cue(name: "title", start: 0.7, duration: 0.8),
        Cue(name: "bezel", start: 1.1, duration: 0.3),
        Cue(name: "headline", start: 1.3),
    ], total: Timing.opening)

    /// One revolution of the red sweep over the enemy's waters.
    private static let sweepPeriod: TimeInterval = 0.8
    /// Where the three contacts light under the red sweep.
    private static let contacts = [UnitPoint(x: 0.68, y: 0.3), UnitPoint(x: 0.32, y: 0.62), UnitPoint(x: 0.6, y: 0.78)]

    var body: some View {
        ZStack {
            switch controller.opening {
            case .matchFound?:
                CuePlayer(sheet: Self.matchFoundSheet, trigger: 0, isSkipped: isSkipped, onCue: handleMatchFound) { frame in
                    matchFound(frame)
                }
                .transition(.opacity)
            case .playing?:
                CuePlayer(sheet: Self.openingSheet, trigger: 1, isSkipped: isSkipped, onCue: handleOpening) { frame in
                    battleStations(frame)
                }
                .transition(.opacity)
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.Curve.phase.policy(policy), value: controller.opening)
        .contentShape(Rectangle())
        .onTapGesture { skip() }
        .accessibilityAction(named: "Skip") { skip() }
    }

    /// What VoiceOver hears in place of the sequence when it collapses.
    static func announcement(for controller: BattleController, app: AppModel?) -> String {
        var parts: [String] = []
        if case .matchFound? = controller.opening, let opponent = app?.online.summary(for: controller.gameID)?.opponent {
            parts.append("Match found: \(opponent.username), rating \(opponent.rating).")
        }
        parts.append("Battle stations.")
        parts.append(controller.headline + ".")
        return parts.joined(separator: " ")
    }

    private func skip() {
        isSkipped = true
        controller.skipOpening()
    }

    private func handleMatchFound(_ cue: String) {
        if cue == "ping" {
            app?.feedback.play(.matchFound)
        }
    }

    private func handleOpening(_ cue: String) {
        switch cue {
        case "slam":
            app?.feedback.play(.opening)
        case "headline":
            onHeadlineCue()
        default:
            break
        }
    }

    // MARK: Match Found

    private func matchFound(_ frame: CueSheet.Frame) -> some View {
        let scrim = frame.progress("scrim")
        let slide = frame.progress("avatars")
        let ratings = frame.progress("ratings")
        let isStacked = dynamicTypeSize.isAccessibilitySize
        let me = app?.session.account
        let opponent = app?.online.summary(for: controller.gameID)?.opponent
        let layout = isStacked
            ? AnyLayout(VStackLayout(spacing: 14))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 18))
        return ZStack {
            Color.black.opacity(0.45 * scrim)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Text("MATCH FOUND")
                    .tracking(2)
                    .scaledFont(12, weight: .heavy, design: .rounded, relativeTo: .caption)
                    .foregroundStyle(Theme.amber)
                    .opacity(frame.progress("caption"))
                layout {
                    contender(name: me?.username ?? "You", rating: me?.stats.rating, from: -1, slide: slide, ratings: ratings, isStacked: isStacked)
                    Text("VS")
                        .displayFont(22, weight: .black)
                        .foregroundStyle(.white.opacity(0.8))
                        .opacity(slide)
                    contender(name: opponent?.username ?? controller.opponentName, rating: opponent?.rating, from: 1, slide: slide, ratings: ratings, isStacked: isStacked)
                }
                if let mode = controller.mode {
                    ModeBadge(mode: mode)
                        .opacity(ratings)
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .hudPanel(cornerRadius: 30)
            .padding()
            .opacity(scrim)
            .scaleEffect(0.96 + 0.04 * scrim)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.announcement(for: controller, app: app))
    }

    /// One side of the VS card, sliding in from its side of the screen.
    private func contender(name: String, rating: Int?, from side: CGFloat, slide: Double, ratings: Double, isStacked: Bool) -> some View {
        VStack(spacing: 6) {
            OpponentAvatar(name: name, size: 64)
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(rating.map { "Rating \($0)" } ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(ratings)
        }
        .frame(maxWidth: .infinity)
        .offset(x: isStacked ? 0 : side * 80 * CGFloat(1 - slide))
        .opacity(slide)
    }

    // MARK: Battle stations

    private func battleStations(_ frame: CueSheet.Frame) -> some View {
        let title = frame.progress("title", curve: Easing.linear)
        return ZStack {
            if let rect = targetBoard, let rules = controller.perspective?.rules {
                let side = min(rect.width, rect.height)
                let geometry = BoardGeometry(boardSize: rules.boardSize, side: side, showsLabels: true)
                let grid = geometry.gridRect.offsetBy(dx: rect.minX, dy: rect.minY)
                let corner = min(14, geometry.cell * 0.35)
                if frame.isActive("sweep") {
                    redSweep(turns: frame.progress("sweep", curve: Easing.linear))
                        .frame(width: grid.width, height: grid.height)
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                        .position(x: grid.midX, y: grid.midY)
                }
                if frame.hasStarted("bezel") {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .trim(from: 0, to: frame.progress("bezel"))
                        .stroke(Theme.reticle.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .glow(Theme.reticle, radius: 6)
                        .frame(width: grid.width, height: grid.height)
                        .position(x: grid.midX, y: grid.midY)
                }
            }
            TitleCard(title: "BATTLE STATIONS", caption: "vs \(controller.opponentName)".uppercased(), tint: .white, progress: title)
                .padding(.horizontal, 24)
                .opacity(frame.hasStarted("title") ? 1 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.announcement(for: controller, app: app))
    }

    /// One revolution of a red beam over the enemy's waters, lighting three contacts that glow and
    /// die; at half opacity where flashes are off.
    private func redSweep(turns: Double) -> some View {
        ZStack {
            SonarBeam(tint: Theme.hit, turns: turns)
            GeometryReader { proxy in
                ForEach(Array(Self.contacts.enumerated()), id: \.offset) { _, contact in
                    RadarContact(
                        tint: Theme.hit,
                        glow: RadarContact.glow(forContactAt: RadarScope.fraction(of: contact), turns: turns, period: Self.sweepPeriod)
                    )
                    .position(x: proxy.size.width * contact.x, y: proxy.size.height * contact.y)
                }
            }
        }
        .opacity(policy.allowsFlashes ? 1 : 0.5)
        .accessibilityHidden(true)
    }
}
