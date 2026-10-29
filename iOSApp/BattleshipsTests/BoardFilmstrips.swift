#if canImport(UIKit)
import BattleshipAPI
import BattleshipCore
import Foundation
import SwiftUI
import Testing
@testable import Battleships

extension ScreenshotTests {
    /// The boards' moments (W2): the final blow with the enemy fleet surfacing after it (FIN-1), the
    /// fleet sailing into its berths at the opening (OPN-2), and the opponent's unseen shots replayed
    /// on the home board when an online game is opened again (BAT-13).
    @Test(.enabled(if: ScreenshotTests.directory != nil))
    func renderBoardFilmstrips() async throws {
        let output = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true).appendingPathComponent("filmstrips", isDirectory: true)
        let showcase = try Showcase()
        let app = showcase.app

        // One cell from victory: a fresh game against an easy computer in which every enemy ship but
        // one is sunk and that one has a single cell left. The computer gets one shot per player shot,
        // sixteen in all, so it cannot have sunk the player's seventeen cells first.
        var match = try app.solo.start(mode: .classic, difficulty: .easy, fleet: Rules.classic.randomFleet())
        let enemy = match.battle.fleet(of: ComputerMatch.computer)
        let spared = try #require(enemy.max { $0.length < $1.length })
        let last = try #require(spared.cells.last)
        for ship in enemy {
            for cell in ship.cells where cell != last {
                try #require(!match.isOver)
                try match.fire(at: cell)
                match.playComputerTurn()
            }
        }
        try #require(!match.isOver)
        app.solo.update(match)
        let finalShotGame = match.id
        try await filmstrip("battle-final-shot", to: output, seconds: 4.0) {
            let controller = BattleController(route: .solo(finalShotGame), app: app)
            return (AnyView(NavigationStack { BattleView(controller: controller) }.environment(app)), controller, { @MainActor in controller.tapTarget(last); Task { await controller.fire() } })
        }

        // A battle that has just begun: BATTLE STATIONS, with the fleet sailing in from the first frame,
        // and the board live by 1.5 s: the strip runs on so the title's leaving is seen too.
        let fresh = try app.solo.start(mode: .classic, difficulty: .medium, fleet: Rules.classic.randomFleet())
        try await filmstrip("battle-opening", to: output, seconds: 4.0, settle: 0) {
            let controller = BattleController(route: .solo(fresh.id), app: app)
            return (AnyView(NavigationStack { BattleView(controller: controller) }.environment(app)), controller, {})
        }

        // An online game opened again after the opponent fired three times: each shot is telegraphed
        // and lands on the home board in turn, one of them a hit on the carrier.
        let seen = SeenMoveCounts(defaults: try #require(UserDefaults(suiteName: "BoardFilmstrips-\(UUID().uuidString)")))
        let summary = makeSummary(status: .active, you: .one, turn: .one, opponent: "nemo")
        let fleet = Rules.classic.randomFleet()
        let carrier = try #require(fleet.first)
        let early = [
            Move(player: .one, target: Coordinate("A1")!, result: .miss),
            Move(player: .two, target: Coordinate("B2")!, result: .miss),
        ]
        let later = early + [
            Move(player: .one, target: Coordinate("C3")!, result: .miss),
            Move(player: .two, target: carrier.origin, result: .hit),
            Move(player: .one, target: Coordinate("E5")!, result: .miss),
            Move(player: .two, target: Coordinate("F6")!, result: .miss),
            Move(player: .one, target: Coordinate("G7")!, result: .miss),
            Move(player: .two, target: Coordinate("H8")!, result: .miss),
        ]
        seen.mark(summary.id, count: early.count)
        app.online.apply(GameDetail(summary: summary, yourFleet: fleet, knownOpponentShips: [], moves: later))
        try await filmstrip("battle-catch-up", to: output, seconds: 2.6, settle: 0) {
            let controller = BattleController(route: .online(summary.id), app: app)
            controller.seenMoveCounts = seen
            return (AnyView(NavigationStack { BattleView(controller: controller) }.environment(app)), controller, {})
        }
    }
}
#endif
