#if canImport(UIKit)
import BattleshipAPI
import BattleshipCore
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Battleships

/// The lobby's moving moments: a game becoming the player's move, the New Battle sheet rising over
/// the dimmed lobby, and a toast. Cut from CI's video like `renderFilmstrips()`'s strips.
extension ScreenshotTests {
    @Test(.enabled(if: ScreenshotTests.directory != nil))
    func renderLobbyFilmstrips() async throws {
        let output = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true).appendingPathComponent("filmstrips", isDirectory: true)
        let showcase = try Showcase()
        let app = showcase.app

        // A game waiting on the opponent becomes the player's move: its row climbs into Your Move,
        // the section's count rolls and a sheen sweeps the row.
        let waiting = try #require(app.online.summaries.first { $0.isTheirTurn })
        try await filmstrip("lobby-your-move", to: output, seconds: 2.4) {
            var summary = waiting
            summary.turn = summary.you
            summary.updatedAt = Date()
            let detail = GameDetail(
                summary: summary,
                yourFleet: summary.mode.rules.randomFleet(),
                knownOpponentShips: [],
                moves: []
            )
            return (AnyView(RootView().environment(app)), nil, { @MainActor in app.online.apply(detail) })
        }

        // The New Battle sheet rises as glass over the lobby, which dims and holds its sea still.
        try await filmstrip("sheet-new-battle", to: output, seconds: 2.4) {
            (AnyView(RootView().environment(app)), nil, { @MainActor in app.newGameRequest = NewGameDraft() })
        }

        // A success toast slides in, its icon bounces, and its hairline drains.
        try await filmstrip("toast", to: output, seconds: 2.4) {
            (AnyView(RootView().environment(app)), nil, { @MainActor in ToastCenter.shared.show(.success, "Challenge sent to nemo") })
        }
    }
}
#endif
