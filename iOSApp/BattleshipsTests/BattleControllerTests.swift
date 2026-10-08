import BattleshipAPI
import BattleshipCore
import Foundation
import Testing
@testable import Battleships

@MainActor
@Suite("Battle screen")
struct BattleControllerTests {
    @Test func aimingThenFiringAgainstTheComputer() async throws {
        let (app, feedback) = makeTestApp()
        let match = try app.solo.start(mode: .quick, difficulty: .easy, fleet: Rules.quick.randomFleet())
        let controller = BattleController(route: .solo(match.id), app: app)
        await controller.load()

        #expect(controller.phase == .battle)
        #expect(controller.isMyTurn)
        #expect(controller.statusLine == "Pick a target in enemy waters.")
        #expect(controller.headline == "Your turn")
        #expect(controller.mood == .ready)
        #expect(!controller.canFire, "nothing aimed yet")

        let target = Coordinate("C3")!
        controller.tapTarget(target)
        #expect(controller.aimed == target)
        #expect(controller.canFire)
        #expect(feedback.events.last == .aim)

        let firing = Task { await controller.fire() }
        // The player's shell lands at once. Its splash or flame only lasts a moment, so look for it
        // before the computer's reply rather than after.
        let landed = { controller.effects.contains { $0.board == .target && $0.coordinate == target } }
        for _ in 0..<100 where !landed() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(landed())
        await firing.value

        // The player's shot, then the computer's reply.
        let played = try #require(app.solo.match(match.id))
        #expect(played.battle.moves.count == 2)
        #expect(played.battle.moves.first?.target == target)
        #expect(controller.aimed == nil)
        #expect(controller.isMyTurn)
        #expect(feedback.events.contains(.fire))
        #expect(feedback.events.contains(.incoming), "the computer's guns are heard")
        #expect(controller.effects.contains { $0.board == .home })
        #expect(controller.announcement != nil, "the computer's shot is announced")
    }

    @Test func refusesSquaresAlreadyFiredAt() async throws {
        let (app, feedback) = makeTestApp()
        let match = try app.solo.start(mode: .quick, difficulty: .easy, fleet: Rules.quick.randomFleet())
        let controller = BattleController(route: .solo(match.id), app: app)
        await controller.load()

        controller.tapTarget(Coordinate("A1")!)
        await controller.fire()
        controller.tapTarget(Coordinate("A1")!)
        #expect(controller.aimed == nil)
        #expect(feedback.events.last == .invalid)
    }

    @Test func tappingTheAimedSquareAgainFires() async throws {
        let (app, _) = makeTestApp()
        let match = try app.solo.start(mode: .classic, difficulty: .medium, fleet: Rules.classic.randomFleet())
        let controller = BattleController(route: .solo(match.id), app: app)
        await controller.load()

        controller.tapTarget(Coordinate("E5")!)
        controller.tapTarget(Coordinate("E5")!)
        // Firing happens in a task; give it (and the computer's reply) time to land.
        for _ in 0..<40 where (app.solo.match(match.id)?.battle.moves.count ?? 0) < 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(app.solo.match(match.id)?.battle.moves.first?.target == Coordinate("E5"))
    }

    @Test func countsHitsSoTheScreenCanReact() async throws {
        let (app, _) = makeTestApp()
        let match = try app.solo.start(mode: .quick, difficulty: .easy, fleet: Rules.quick.randomFleet())
        let controller = BattleController(route: .solo(match.id), app: app)
        await controller.load()

        let enemyBoat = try #require(match.battle.fleet(of: ComputerMatch.computer).first)
        controller.tapTarget(enemyBoat.origin)
        await controller.fire()
        #expect(controller.hitsLanded == 1)
        let computerHits = app.solo.match(match.id)?.perspective.enemyStats.hits ?? -1
        #expect(controller.hitsTaken == computerHits)
    }

    @Test func resigningEndsTheBattle() async throws {
        let (app, feedback) = makeTestApp()
        let match = try app.solo.start(mode: .classic, difficulty: .hard, fleet: Rules.classic.randomFleet())
        let controller = BattleController(route: .solo(match.id), app: app)
        await controller.load()

        await controller.resign()
        #expect(controller.phase == .finished)
        #expect(controller.statusLine == "You resigned.")
        #expect(controller.headline == "Defeat")
        #expect(controller.mood == .defeat)
        #expect(controller.perspective?.didWin == false)
        #expect(app.solo.record.losses[.hard] == 1)
        #expect(feedback.events.contains(.defeat))
    }

    @Test func reopeningAFinishedGameDoesNotReplayIt() async throws {
        let (app, feedback) = makeTestApp()
        let match = try app.solo.start(mode: .quick, difficulty: .easy, fleet: Rules.quick.randomFleet())
        let first = BattleController(route: .solo(match.id), app: app)
        await first.load()
        await first.resign()
        #expect(feedback.events.filter { $0 == .defeat }.count == 1)

        let reopened = BattleController(route: .solo(match.id), app: app)
        await reopened.load()
        #expect(reopened.phase == .finished)
        #expect(reopened.effects.isEmpty)
        #expect(feedback.events.filter { $0 == .defeat }.count == 1, "the defeat isn't replayed")
        #expect(!reopened.showsOutcome)
    }

    @Test func aGameThatEndedElsewhereShowsItsResultOnce() async throws {
        let (app, feedback) = makeTestApp()
        // As if the opponent's last shot landed while the player was in the lobby.
        var match = try app.solo.start(mode: .quick, difficulty: .easy, fleet: Rules.quick.randomFleet())
        try match.resign()
        app.solo.update(match)

        let controller = BattleController(route: .solo(match.id), app: app)
        await controller.load()
        #expect(feedback.events.contains(.defeat))
        for _ in 0..<30 where !controller.showsOutcome {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(controller.showsOutcome)

        let reopened = BattleController(route: .solo(match.id), app: app)
        await reopened.load()
        #expect(feedback.events.filter { $0 == .defeat }.count == 1)
    }

    @Test func leavingCallsOffTheComputersReply() async throws {
        let (app, feedback) = makeTestApp()
        let match = try app.solo.start(mode: .quick, difficulty: .easy, fleet: Rules.quick.randomFleet())
        let controller = BattleController(route: .solo(match.id), app: app)
        await controller.load()

        controller.tapTarget(Coordinate("A1")!)
        let firing = Task { await controller.fire() }
        for _ in 0..<50 where !controller.isComputerThinking {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.isComputerThinking)
        controller.viewDidDisappear()
        await firing.value

        #expect(app.solo.match(match.id)?.battle.moves.count == 1, "the computer holds its fire")
        #expect(!feedback.events.contains(.incoming))

        // Back on the screen, the computer takes its turn.
        let reopened = BattleController(route: .solo(match.id), app: app)
        reopened.viewDidAppear()
        await reopened.load()
        #expect(app.solo.match(match.id)?.battle.moves.count == 2)
    }

    @Test func missesAreReadOutWithoutABanner() async throws {
        let (app, _) = makeTestApp()
        let match = try app.solo.start(mode: .quick, difficulty: .easy, fleet: Rules.quick.randomFleet())
        let controller = BattleController(route: .solo(match.id), app: app)
        await controller.load()

        let occupied = Set(match.battle.fleet(of: ComputerMatch.computer).flatMap(\.cells))
        let water = try #require(Rules.quick.allCoordinates.first { !occupied.contains($0) })
        controller.tapTarget(water)
        let firing = Task { await controller.fire() }
        // Before the computer replies, only the player's miss has been announced.
        for _ in 0..<50 where controller.spokenAnnouncement == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.spokenAnnouncement?.message == "Miss at \(water).")
        #expect(controller.spokenAnnouncement?.source == .player)
        #expect(controller.announcement == nil, "a miss gets no banner")
        await firing.value
    }

    @Test func missingGamesAreReportedAsUnavailable() async {
        let (app, _) = makeTestApp()
        let controller = BattleController(route: .solo(UUID()), app: app)
        await controller.load()
        #expect(controller.phase == .unavailable("This game no longer exists."))
    }

    @Test func rematchPrefillsTheNewGameSheet() throws {
        let (app, _) = makeTestApp()
        let match = try app.solo.start(mode: .quick, difficulty: .hard, fleet: Rules.quick.randomFleet())
        app.requestRematch(of: .solo(match.id))
        #expect(app.newGameRequest == NewGameDraft(opponent: .computer, difficulty: .hard, mode: .quick))
    }
}
