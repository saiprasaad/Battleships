#if canImport(UIKit)
import BattleshipAPI
import BattleshipCore
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Battleships

/// The battle screen's moments (W3): an opponent found while the player waits (the VS card, then
/// BATTLE STATIONS over the boards) and the HUD on the opponent's turn with their clock draining.
/// Cut from CI's video like `renderFilmstrips()`'s strips.
extension ScreenshotTests {
    @Test(.enabled(if: ScreenshotTests.directory != nil))
    func renderBattleScreenFilmstrips() async throws {
        let output = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true).appendingPathComponent("filmstrips", isDirectory: true)
        let showcase = try Showcase()
        let app = showcase.app

        // The player is searching; half a second into the strip nemo appears: Match Found, then
        // BATTLE STATIONS, then the board goes live.
        let searching = BattleStripGame.make(status: .matchmaking, opponent: nil, turn: nil, moves: [], fleet: Rules.classic.randomFleet())
        let found: GameDetail = {
            var game = searching
            game.summary.status = .active
            game.summary.opponent = PlayerSummary(id: UUID(), username: "nemo", rating: 1240)
            game.summary.turn = .one
            game.summary.updatedAt = Date()
            return game
        }()
        try await filmstrip("battle-match-found", to: output, seconds: 3.6) {
            app.online.apply(searching)
            return (
                AnyView(NavigationStack { BattleView(route: .online(searching.id), app: app) }.environment(app)),
                nil,
                {
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        app.online.apply(found)
                    }
                }
            )
        }

        // Their turn, with three hours left on a day's clock: the arc around the status dot is
        // nearly drained and the player's waters wait under the red sweep.
        var duel = try Battle(mode: .classic, fleetOne: Rules.classic.randomFleet(), fleetTwo: Rules.classic.randomFleet())
        for notation in ["B2", "C7", "D4"] {
            if let player = duel.turn, let cell = Coordinate(notation) {
                try duel.fire(player, at: cell)
            }
        }
        let timed = BattleStripGame.make(
            status: .active,
            opponent: PlayerSummary(id: UUID(), username: "drake", rating: 1088),
            turn: .two,
            moves: duel.moves,
            fleet: duel.fleet(of: .one),
            updatedAt: Date(timeIntervalSinceNow: -21 * 3600),
            turnDeadline: Date(timeIntervalSinceNow: 3 * 3600)
        )
        try await filmstrip("battle-turn-timer", to: output, seconds: 2.4) {
            app.online.apply(timed)
            return (AnyView(NavigationStack { BattleView(route: .online(timed.id), app: app) }.environment(app)), nil, {})
        }
    }
}

/// Online games built by hand for the battle strips: the player is seat one.
enum BattleStripGame {
    static func make(
        status: GameStatus,
        opponent: PlayerSummary?,
        turn: Player?,
        moves: [Move],
        fleet: [ShipPlacement],
        updatedAt: Date = Date(),
        turnDeadline: Date? = nil
    ) -> GameDetail {
        let summary = GameSummary(
            id: UUID(),
            mode: .classic,
            status: status,
            you: .one,
            opponent: opponent,
            turn: turn,
            outcome: nil,
            yourShipsRemaining: Rules.classic.fleet.count,
            opponentShipsRemaining: Rules.classic.fleet.count,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            turnDeadline: turnDeadline
        )
        return GameDetail(summary: summary, yourFleet: fleet, knownOpponentShips: [], moves: moves)
    }
}
#endif
