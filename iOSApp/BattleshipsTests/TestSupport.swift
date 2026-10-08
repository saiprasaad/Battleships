import BattleshipAPI
import BattleshipCore
import Foundation
@testable import Battleships

/// Records feedback instead of playing haptics.
@MainActor
final class FeedbackRecorder: FeedbackPlayer {
    private(set) var events: [FeedbackEvent] = []

    func play(_ event: FeedbackEvent) {
        events.append(event)
    }
}

/// An app model with nothing persisted outside a throwaway directory.
@MainActor
func makeTestApp() -> (app: AppModel, feedback: FeedbackRecorder) {
    let defaults = UserDefaults(suiteName: "BattleshipsTests-\(UUID().uuidString)")!
    let feedback = FeedbackRecorder()
    let app = AppModel(
        settings: AppSettings(defaults: defaults),
        tokenStorage: InMemoryTokenStorage(),
        feedback: feedback,
        soloDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    )
    return (app, feedback)
}

func makeSummary(
    status: GameStatus,
    you: Player = .one,
    turn: Player? = nil,
    outcome: Outcome? = nil,
    updatedAt: Date = Date(),
    turnDeadline: Date? = nil,
    opponent: String? = "rival"
) -> GameSummary {
    GameSummary(
        id: UUID(),
        mode: .classic,
        status: status,
        you: you,
        opponent: opponent.map { PlayerSummary(id: UUID(), username: $0, rating: 1000) },
        turn: turn,
        outcome: outcome,
        yourShipsRemaining: 5,
        opponentShipsRemaining: 5,
        createdAt: updatedAt,
        updatedAt: updatedAt,
        turnDeadline: turnDeadline
    )
}
