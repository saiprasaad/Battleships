#if canImport(UIKit)
import BattleshipCore
import Foundation
import SwiftUI
import Testing
@testable import Battleships

extension ScreenshotTests {
    /// The deploy screen's moments (DEP-1, DEP-2): the fleet dropping anchor under a "vs" chip, a
    /// ship turning about its origin cell, and the cast-off from the lock brackets to the empty board.
    @Test(.enabled(if: ScreenshotTests.directory != nil))
    func renderDeployFilmstrips() async throws {
        let output = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true).appendingPathComponent("filmstrips", isDirectory: true)
        let showcase = try Showcase()
        let app = showcase.app

        // The arrival plays as the screen appears, so the strip starts at once.
        try await filmstrip("deploy-arrival", to: output, seconds: 2.0, settle: 0) {
            let screen = NavigationStack {
                FleetPlacementView(mode: .classic, confirmTitle: "Start Battle", opponentDisplayName: "nemo") { _ in }
            }
            return (AnyView(screen.environment(app)), nil, {})
        }

        // The carrier turns (and slides along if it has to fit).
        try await filmstrip("deploy-rotate", to: output, seconds: 1.6) {
            let director = PlacementDirector()
            let screen = NavigationStack {
                FleetPlacementView(mode: .classic, confirmTitle: "Start Battle", director: director) { _ in }
            }
            return (AnyView(screen.environment(app)), nil, { director.rotate(0) })
        }

        // The request is instant; the hand-over waits for the departure, then holds on the empty board.
        try await filmstrip("deploy-castoff", to: output, seconds: 2.4) {
            let director = PlacementDirector()
            let screen = NavigationStack {
                FleetPlacementView(mode: .classic, confirmTitle: "Start Battle", director: director) { _, handoff in
                    await handoff.departed()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            return (AnyView(screen.environment(app)), nil, { director.deploy() })
        }
    }
}
#endif
