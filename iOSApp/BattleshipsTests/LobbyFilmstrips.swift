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

        // The horizon's life, started where the timetable has the ship two thirds across, a flight
        // of three gulls leaving half a second in and the lamp flashing within the first second
        // and again five seconds later.
        try await filmstrip("lobby-horizon", to: output, seconds: 7.0, settle: 0) {
            let offset = 60.5 - Date().timeIntervalSinceReferenceDate - 0.8
            return (AnyView(HorizonStrip(sceneryTimeOffset: offset).environment(app)), nil, {})
        }

        // The sheet's pickers: the selection frame slides to Friend and back to Computer, the
        // difficulty thumb slides to Admiral and back to Captain with its chevrons lighting.
        try await filmstrip("sheet-pickers", to: output, seconds: 3.0) {
            let probe = PickerProbe()
            return (
                AnyView(SheetPickersStrip(probe: probe).environment(app)),
                nil,
                {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        withAnimation(Motion.Curve.snap) { probe.opponent = .friend }
                        try? await Task.sleep(for: .milliseconds(700))
                        withAnimation(Motion.Curve.snap) { probe.difficulty = .hard }
                        try? await Task.sleep(for: .milliseconds(700))
                        withAnimation(Motion.Curve.snap) { probe.opponent = .computer }
                        try? await Task.sleep(for: .milliseconds(700))
                        withAnimation(Motion.Curve.snap) { probe.difficulty = .medium }
                    }
                }
            )
        }
    }
}

/// The lobby's horizon on its own, taller than the hero shows it, over the sky.
private struct HorizonStrip: View {
    let sceneryTimeOffset: TimeInterval

    var body: some View {
        ZStack {
            OceanBackdrop(isAnimated: false)
            VStack {
                Spacer()
                HorizonScene(shipPosition: 0.68, shipWidth: 128, isLively: true, shipVoyages: true, sceneryTimeOffset: sceneryTimeOffset)
                    .frame(height: 150)
                Spacer()
            }
        }
    }
}

/// The sheet's two pickers, driven from outside.
@MainActor
@Observable
final class PickerProbe {
    var opponent: OpponentChoice = .computer
    var difficulty: Difficulty = .easy
}

private struct SheetPickersStrip: View {
    let probe: PickerProbe

    var body: some View {
        ZStack {
            OceanBackdrop(isAnimated: false)
            VStack(spacing: 28) {
                SheetSectionHeader(title: "Opponent")
                OpponentPicker(selection: Binding(get: { probe.opponent }, set: { probe.opponent = $0 }))
                SheetSectionHeader(title: "Difficulty")
                DifficultyDial(selection: Binding(get: { probe.difficulty }, set: { probe.difficulty = $0 }))
            }
            .padding(24)
        }
    }
}
#endif
