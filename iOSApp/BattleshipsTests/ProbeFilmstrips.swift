#if canImport(UIKit)
import BattleshipAPI
import BattleshipCore
import Foundation
import SwiftUI
import Testing
@testable import Battleships

/// Strips that measure the stage rather than the game, for reading the others: how SwiftUI's own
/// animations and transitions progress on CI's simulator, and what the Match Found opening costs on
/// its own and under a battle. Cut from CI's video like `renderFilmstrips()`'s strips; the timeline's
/// stalls say what the main thread was doing.
extension ScreenshotTests {
    @Test(.enabled(if: ScreenshotTests.directory != nil))
    func renderProbeFilmstrips() async throws {
        let output = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true).appendingPathComponent("filmstrips", isDirectory: true)
        let showcase = try Showcase()
        let app = showcase.app

        // Four plain animations started by the action: a fade, a removal, the removal of a view with
        // a running clock inside, and a text content transition. Each should be over 0.3 s later.
        try await filmstrip("probe-animations", to: output, seconds: 3.0) {
            let probe = ProbeSwitch()
            return (AnyView(AnimationProbe(probe: probe)), nil, { @MainActor in probe.isOn = true })
        }

        // The Match Found card alone, over the ocean: an opponent found half a second in.
        let searching = BattleStripGame.make(status: .matchmaking, opponent: nil, turn: nil, moves: [], fleet: Rules.classic.randomFleet())
        let found = BattleStripGame.found(searching, opponent: "nemo")
        try await filmstrip("probe-match-card", to: output, seconds: 3.6) {
            app.online.apply(searching)
            let controller = BattleController(route: .online(searching.id), app: app)
            controller.viewDidAppear()
            return (
                AnyView(ZStack { OceanBackdrop(); BattleOpening(controller: controller) }.environment(app)),
                controller,
                {
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        app.online.apply(found)
                    }
                }
            )
        }

        // The battle of a game found before the screen opened: BATTLE STATIONS without the card.
        let searching2 = BattleStripGame.make(status: .matchmaking, opponent: nil, turn: nil, moves: [], fleet: Rules.classic.randomFleet())
        let found2 = BattleStripGame.found(searching2, opponent: "drake")
        try await filmstrip("probe-found-battle", to: output, seconds: 3.0) {
            app.online.apply(found2)
            return (AnyView(NavigationStack { BattleView(route: .online(found2.id), app: app) }.environment(app)), nil, {})
        }
    }
}

extension BattleStripGame {
    /// `game` with `opponent` found: active, the player (seat one) to move.
    static func found(_ game: GameDetail, opponent: String) -> GameDetail {
        var found = game
        found.summary.status = .active
        found.summary.opponent = PlayerSummary(id: UUID(), username: opponent, rating: 1240)
        found.summary.turn = .one
        found.summary.updatedAt = Date()
        return found
    }
}

/// A switch a probe flips after its first frame.
@MainActor
@Observable
final class ProbeSwitch {
    var isOn = false
}

/// Four animations on one screen, each labelled, started by `probe.isOn`.
struct AnimationProbe: View {
    let probe: ProbeSwitch

    var body: some View {
        let isOn = probe.isOn
        ZStack {
            Color(red: 0.05, green: 0.1, blue: 0.2).ignoresSafeArea()
            VStack(spacing: 24) {
                // 1. A fade through `.animation(value:)`.
                row("fade") {
                    Rectangle()
                        .fill(Color.yellow)
                        .opacity(isOn ? 0.2 : 1)
                        .animation(.easeInOut(duration: 0.3), value: isOn)
                }
                // 2. A removal with a transition.
                row("removal") {
                    ZStack {
                        if !isOn {
                            Rectangle().fill(Color.orange).transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: isOn)
                }
                // 3. The removal of a view with a running clock inside it.
                row("clocked removal") {
                    ZStack {
                        if !isOn {
                            LoopClock(loop: .ambient) { time in
                                Rectangle()
                                    .fill(Color.green)
                                    .frame(width: 24, height: 60)
                                    .rotationEffect(.degrees((time ?? 0) * 90))
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: isOn)
                }
                // 4. A text content transition, as the Fire bar's caption uses.
                row("caption") {
                    Text(isOn ? "TARGET" : "STAND BY")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: isOn)
                }
            }
            .padding(24)
        }
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 110, alignment: .leading)
            content()
                .frame(width: 160, height: 60)
        }
    }
}
#endif
