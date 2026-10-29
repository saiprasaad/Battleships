import BattleshipAPI
import BattleshipCore
import Foundation
@testable import Battleships

/// Records feedback instead of playing haptics: every play with its variation, the engine
/// prepare/rest calls, loops and ambient scenes.
@MainActor
final class FeedbackRecorder: FeedbackPlayer {
    struct Play: Equatable, Sendable {
        let event: FeedbackEvent
        let variation: FeedbackVariation
    }

    struct LoopChange: Equatable, Sendable {
        let event: FeedbackEvent
        let isOn: Bool
    }

    /// Every event played, in order (the variation is in `plays`).
    private(set) var events: [FeedbackEvent] = []
    private(set) var plays: [Play] = []
    private(set) var loops: [LoopChange] = []
    private(set) var scenes: [AmbientScene] = []
    private(set) var prepareCount = 0
    private(set) var restCount = 0

    func play(_ event: FeedbackEvent) {
        play(event, variation: .default)
    }

    func play(_ event: FeedbackEvent, variation: FeedbackVariation) {
        events.append(event)
        plays.append(Play(event: event, variation: variation))
    }

    func prepare() {
        prepareCount += 1
    }

    func rest() {
        restCount += 1
    }

    func setLoop(_ event: FeedbackEvent, isOn: Bool) {
        loops.append(LoopChange(event: event, isOn: isOn))
    }

    func setAmbientScene(_ scene: AmbientScene) {
        scenes.append(scene)
    }

    /// The variation of the last play of `event`, if it was played.
    func variation(of event: FeedbackEvent) -> FeedbackVariation? {
        plays.last { $0.event == event }?.variation
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
