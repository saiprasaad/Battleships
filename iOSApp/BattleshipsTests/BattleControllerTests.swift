import BattleshipAPI
import BattleshipClient
import BattleshipCore
import Foundation
import Testing
@testable import Battleships

/// Waits for `condition` to hold, checking every 10 ms for up to `seconds`. The battle's beats run on
/// real time, so tests with a beat longer than 0 wait for it this way. Only states that then stay
/// are waited for: with a hundred tests sharing the main actor, a short-lived one can be missed.
@MainActor
private func eventually(_ seconds: Double = 10, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// An app with a signed-in player, which an online battle needs to be shown at all.
@MainActor
private func makeSignedInTestApp() throws -> (app: AppModel, feedback: FeedbackRecorder) {
    let defaults = try #require(UserDefaults(suiteName: "BattleTests-\(UUID().uuidString)"))
    let account = Account(id: UUID(), username: "captain", createdAt: Date(), stats: PlayerStats(rating: 1000, wins: 0, losses: 0))
    defaults.set(try APICoding.makeEncoder().encode(account), forKey: "cachedAccount")
    let feedback = FeedbackRecorder()
    let app = AppModel(
        settings: AppSettings(defaults: defaults),
        tokenStorage: InMemoryTokenStorage(token: "test"),
        feedback: feedback,
        soloDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
        defaults: defaults
    )
    return (app, feedback)
}

/// A game against the computer on the battle screen. Quick rules by default: five one-square boats,
/// so every hit is a sunk and a player who only fires at boats always wins before the computer can.
/// Every beat is instant and splashes stay for a minute unless a test says otherwise.
@MainActor
private func makeSoloBattle(
    mode: GameMode = .quick,
    difficulty: Difficulty = .easy,
    computerPause: ClosedRange<Int> = 0...0
) throws -> (app: AppModel, feedback: FeedbackRecorder, match: ComputerMatch, controller: BattleController) {
    let (app, feedback) = makeTestApp()
    let match = try app.solo.start(mode: mode, difficulty: difficulty, fleet: mode.rules.randomFleet())
    let controller = BattleController(route: .solo(match.id), app: app)
    controller.beats = .instant
    controller.impactDuration = .seconds(60)
    controller.computerPause = computerPause
    return (app, feedback, match, controller)
}

/// A square of open water on the computer's board.
private func water(in match: ComputerMatch) throws -> Coordinate {
    let occupied = Set(match.battle.fleet(of: ComputerMatch.computer).flatMap(\.cells))
    let fired = Set(match.battle.moves.filter { $0.player == ComputerMatch.human }.map(\.target))
    return try #require(match.mode.rules.allCoordinates.first { !occupied.contains($0) && !fired.contains($0) })
}

private func isMatchFound(_ opening: BattleController.Opening?) -> Bool {
    if case .matchFound = opening { return true }
    return false
}

@MainActor
@Suite("Battle screen")
struct BattleControllerTests {
    @Test func aimingThenFiringAgainstTheComputer() async throws {
        let (app, feedback) = makeTestApp()
        let match = try app.solo.start(mode: .quick, difficulty: .easy, fleet: Rules.quick.randomFleet())
        let controller = BattleController(route: .solo(match.id), app: app)
        // Everything lands at once, and splashes and flames (which normally fade after a second) stay
        // so they can be checked.
        controller.beats = .instant
        controller.impactDuration = .seconds(60)
        controller.computerPause = 0...0
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

        await controller.fire()

        // The player's shot, then the computer's reply.
        let played = try #require(app.solo.match(match.id))
        #expect(played.battle.moves.count == 2)
        #expect(played.battle.moves.first?.target == target)
        #expect(controller.aimed == nil)
        #expect(controller.isMyTurn)
        #expect(feedback.events.contains(.fire))
        #expect(feedback.events.contains(.incoming), "the computer's guns are heard")
        #expect(controller.effects.contains { $0.board == .target && $0.coordinate == target })
        #expect(controller.effects.contains { $0.board == .home })
        #expect(controller.announcement != nil, "the computer's shot is announced")
    }

    @Test func refusesSquaresAlreadyFiredAt() async throws {
        let (app, feedback) = makeTestApp()
        let match = try app.solo.start(mode: .quick, difficulty: .easy, fleet: Rules.quick.randomFleet())
        let controller = BattleController(route: .solo(match.id), app: app)
        controller.beats = .instant
        controller.computerPause = 0...0
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
        controller.beats = .instant
        controller.computerPause = 0...0
        await controller.load()

        controller.tapTarget(Coordinate("E5")!)
        controller.tapTarget(Coordinate("E5")!)
        // Firing happens in a task; give it (and the computer's reply) time to land.
        for _ in 0..<200 where (app.solo.match(match.id)?.battle.moves.count ?? 0) < 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(app.solo.match(match.id)?.battle.moves.first?.target == Coordinate("E5"))
    }

    @Test func countsHitsSoTheScreenCanReact() async throws {
        let (app, _) = makeTestApp()
        let match = try app.solo.start(mode: .quick, difficulty: .easy, fleet: Rules.quick.randomFleet())
        let controller = BattleController(route: .solo(match.id), app: app)
        controller.beats = .instant
        controller.computerPause = 0...0
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
        #expect(controller.finale == nil, "giving up isn't a finale")
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
        for _ in 0..<200 where !controller.showsOutcome {
            try await Task.sleep(for: .milliseconds(50))
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
        controller.beats = .instant
        // A computer that thinks for a minute, so the player is sure to leave before it fires.
        controller.computerPause = 60_000...60_000
        await controller.load()

        controller.tapTarget(Coordinate("A1")!)
        let firing = Task { await controller.fire() }
        for _ in 0..<1_000 where !controller.isComputerThinking {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.isComputerThinking)
        controller.viewDidDisappear()
        await firing.value

        #expect(!controller.isComputerThinking)
        #expect(app.solo.match(match.id)?.battle.moves.count == 1, "the computer holds its fire")
        #expect(!feedback.events.contains(.incoming))

        // Back on the screen, the computer takes its turn.
        let reopened = BattleController(route: .solo(match.id), app: app)
        reopened.beats = .instant
        reopened.computerPause = 0...0
        reopened.viewDidAppear()
        await reopened.load()
        #expect(app.solo.match(match.id)?.battle.moves.count == 2)
    }

    @Test func missesAreReadOutWithoutABanner() async throws {
        let (app, _) = makeTestApp()
        let match = try app.solo.start(mode: .quick, difficulty: .easy, fleet: Rules.quick.randomFleet())
        let controller = BattleController(route: .solo(match.id), app: app)
        controller.beats = .instant
        controller.computerPause = 60_000...60_000
        await controller.load()

        let occupied = Set(match.battle.fleet(of: ComputerMatch.computer).flatMap(\.cells))
        let water = try #require(Rules.quick.allCoordinates.first { !occupied.contains($0) })
        controller.tapTarget(water)
        let firing = Task { await controller.fire() }
        // While the computer is still taking aim, only the player's miss has been announced.
        for _ in 0..<1_000 where !controller.isComputerThinking {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.spokenAnnouncement?.message == "Miss at \(water).")
        #expect(controller.spokenAnnouncement?.source == .player)
        #expect(controller.announcement == nil, "a miss gets no banner")
        controller.viewDidDisappear()
        await firing.value
    }

    @Test func missingGamesAreReportedAsUnavailable() async {
        let (app, _) = makeTestApp()
        let controller = BattleController(route: .solo(UUID()), app: app)
        await controller.load()
        #expect(controller.phase == .unavailable("This game no longer exists."))
    }

    @Test func rematchGoesStraightToDeploy() throws {
        let (app, _) = makeTestApp()
        let match = try app.solo.start(mode: .quick, difficulty: .hard, fleet: Rules.quick.randomFleet())
        app.requestRematch(of: .solo(match.id))
        let draft = try #require(app.newGameRequest)
        #expect(draft.isRematch)
        #expect(draft.opponent == .computer)
        #expect(draft.difficulty == .hard)
        #expect(draft.mode == .quick)
        #expect(draft.opponentDisplayName == "Computer · Admiral")
    }

    @Test func startingAGameFromADraftOpensIt() async throws {
        let (app, _) = makeTestApp()
        let draft = NewGameDraft(opponent: .computer, difficulty: .easy, mode: .quick)
        let route = try await app.startGame(draft, fleet: Rules.quick.randomFleet())
        guard case let .solo(id) = route else {
            Issue.record("a game against the computer is a solo route")
            return
        }
        #expect(app.solo.match(id)?.difficulty == .easy)
    }

    // MARK: The shot loop

    @Test func theShellIsInTheAirUntilItLands() async throws {
        let (_, feedback, match, controller) = try makeSoloBattle(computerPause: 60_000...60_000)
        // A flight that lasts the whole test, so what is true in the air can be checked at leisure.
        controller.beats.shellFlight = 60
        await controller.load()
        let target = try water(in: match)
        controller.tapTarget(target)
        let firing = Task { await controller.fire() }
        try await eventually { controller.shells.count == 1 }

        // In the air: the engine has decided, but nothing has happened on screen yet.
        let shell = try #require(controller.shells.first)
        #expect(shell.board == .target)
        #expect(shell.coordinate == target)
        #expect(shell.outcome == .miss, "the engine decides at once")
        let flight = try #require(shell.lands).timeIntervalSince(shell.start)
        #expect(abs(flight - 60) < 0.001)
        #expect(controller.impacts.isEmpty)
        #expect(controller.isSubmitting)
        #expect(!controller.isMyTurn)
        #expect(!controller.canFire)
        #expect(controller.displayedTurn == ComputerMatch.human, "the HUD keeps the turn until the landing")
        #expect(controller.headline == "Your turn")
        #expect(feedback.events.last == .fire)
        #expect(controller.spokenAnnouncement == nil)
        #expect(controller.latestOwnShot == nil)
        #expect(!controller.targetClock.isFrozen)
        #expect(controller.hitsLanded == 0)
        #expect(controller.hitStreak == 0)

        controller.viewDidDisappear()
        await firing.value
    }

    @Test func theLandingComesWhenTheShellDoes() async throws {
        let (_, feedback, match, controller) = try makeSoloBattle(computerPause: 60_000...60_000)
        controller.beats.shellFlight = 0.2
        await controller.load()
        let target = try water(in: match)
        controller.tapTarget(target)
        let fired = Date()
        let firing = Task { await controller.fire() }
        try await eventually { !controller.impacts.isEmpty }

        let impact = try #require(controller.impacts.first)
        #expect(impact.board == .target)
        #expect(impact.coordinate == target)
        #expect(!impact.isHit)
        #expect(impact.start >= fired.addingTimeInterval(0.2 - 0.02), "never before the flight is over")
        #expect(controller.shells.isEmpty, "the impact takes over from the shell")
        #expect(!controller.isSubmitting, "input reopens at the landing")
        #expect(controller.latestOwnShot == target)
        #expect(controller.displayedTurn == ComputerMatch.computer)
        #expect(controller.isComputerThinking, "and the computer's pause begins")
        let firedAt = try #require(feedback.events.firstIndex(of: .fire))
        let landedAt = try #require(feedback.events.firstIndex(of: .miss))
        #expect(landedAt > firedAt)
        #expect(controller.spokenAnnouncement?.message == "Miss at \(target).")
        // Effect time on the enemy's waters stood still for the hit-stop.
        let clock = controller.targetClock
        #expect(clock.time(at: impact.start.addingTimeInterval(0.03)) == clock.time(at: impact.start))
        #expect(clock.time(at: impact.start.addingTimeInterval(Timing.hitStop + 0.1)) > clock.time(at: impact.start))

        controller.viewDidDisappear()
        await firing.value
    }

    @Test func nothingIsReactedToBeforeTheLanding() async throws {
        let (app, feedback, match, controller) = try makeSoloBattle()
        controller.beats.shellFlight = 60
        await controller.load()
        let boat = try #require(match.battle.fleet(of: ComputerMatch.computer).first)
        controller.tapTarget(boat.origin)
        let firing = Task { await controller.fire() }
        try await eventually { controller.shells.count == 1 }

        #expect(app.solo.match(match.id)?.battle.moves.count == 1, "the move is made at once")
        #expect(controller.hitsLanded == 0)
        #expect(controller.hitStreak == 0)
        #expect(controller.sinkings.isEmpty)
        #expect(controller.announcement == nil)
        #expect(!feedback.events.contains(.sunk))
        #expect(!feedback.events.contains(.hit))
        #expect(!controller.targetClock.isFrozen)

        // Landing it now reacts to it in full.
        controller.skipSequences()
        await firing.value
        #expect(controller.hitsLanded == 1)
        #expect(controller.hitStreak == 1)
        #expect(controller.latestOwnShot == boat.origin)
        let sunkAt = try #require(feedback.events.firstIndex(of: .sunk))
        let stampedAt = try #require(feedback.events.firstIndex(of: .stamp))
        let repliedAt = try #require(feedback.events.firstIndex(of: .incoming))
        #expect(sunkAt < stampedAt, "the stamp followed")
        #expect(stampedAt < repliedAt, "then the computer's reply, which took the banner")
        #expect(controller.spokenAnnouncement?.source == .opponent)
    }

    @Test func aSunkShipSinksThenIsStamped() async throws {
        let (app, feedback, match, controller) = try makeSoloBattle()
        controller.beats.sunkStamp = 0.3
        controller.beats.stampHold = 60
        controller.beats.sinking = 60
        await controller.load()
        let boat = try #require(match.battle.fleet(of: ComputerMatch.computer).first)
        controller.tapTarget(boat.origin)
        await controller.fire()

        let sinking = try #require(controller.sinkings.first)
        #expect(sinking.board == .target)
        #expect(sinking.ship == boat)
        #expect(controller.impacts.first?.isSunk == true)
        let stamp = try #require(controller.stamps.first)
        #expect(stamp.board == .target)
        #expect(stamp.ship == boat)
        #expect(stamp.start.timeIntervalSince(sinking.start) >= 0.3 - 0.02, "the stamp follows the sinking")
        let sunkAt = try #require(feedback.events.firstIndex(of: .sunk))
        let stampedAt = try #require(feedback.events.firstIndex(of: .stamp))
        let repliedAt = try #require(feedback.events.firstIndex(of: .incoming))
        #expect(sunkAt < stampedAt)
        #expect(stampedAt < repliedAt, "the computer waits for the stamp")
        let played = try #require(app.solo.match(match.id))
        #expect(played.battle.moves.count == 2)
        #expect(played.updatedAt >= stamp.start.addingTimeInterval(-0.02))
    }

    @Test func theTelegraphShowsTheCellTheComputerWillFireAt() async throws {
        let (app, feedback, match, controller) = try makeSoloBattle(computerPause: 60_000...60_000)
        // The telegraph is the whole pause: it is up from the player's landing until the test lands it.
        controller.beats.whistle = 60
        await controller.load()
        controller.tapTarget(try water(in: match))
        let firing = Task { await controller.fire() }
        try await eventually { controller.telegraph != nil }

        let telegraph = try #require(controller.telegraph)
        #expect(abs(telegraph.lands.timeIntervalSince(telegraph.start) - 60) < 0.001)
        #expect(controller.isComputerThinking)
        #expect(controller.headline == "Incoming")
        #expect(controller.mood == .danger)
        #expect(!controller.isMyTurn)
        #expect(controller.impacts.allSatisfy { $0.board == .target }, "nothing has landed on the home board yet")
        let incomingAt = try #require(feedback.events.lastIndex(of: .incoming))
        #expect(feedback.events[incomingAt...].contains(.whistle))
        #expect(app.solo.match(match.id)?.battle.moves.count == 1, "the shot hasn't been made yet")

        controller.skipSequences()
        await firing.value
        #expect(app.solo.match(match.id)?.battle.moves.last?.target == telegraph.coordinate, "the computer fires where it said it would")
        #expect(controller.latestEnemyShot == telegraph.coordinate)
        #expect(controller.telegraph == nil)
        #expect(!controller.isComputerThinking)
        #expect(controller.displayedTurn == ComputerMatch.human)
        #expect(controller.isMyTurn, "input reopens at the enemy's landing")
        #expect(controller.spokenAnnouncement?.source == .opponent)
    }

    @Test func theEnemyLandingWaitsForThePause() async throws {
        let (_, feedback, match, controller) = try makeSoloBattle(computerPause: 300...300)
        controller.beats.whistle = 0.1
        await controller.load()
        controller.tapTarget(try water(in: match))
        await controller.fire()

        let mine = try #require(controller.impacts.first { $0.board == .target })
        let theirs = try #require(controller.impacts.first { $0.board == .home })
        #expect(theirs.start >= mine.start.addingTimeInterval(0.3 - 0.02), "the pause runs from the player's landing")
        let incomingAt = try #require(feedback.events.firstIndex(of: .incoming))
        let whistleAt = try #require(feedback.events.firstIndex(of: .whistle))
        let myLandingAt = try #require(feedback.events.firstIndex(of: .miss))
        // The enemy's landing sounds as a miss, a near miss, or a hit or sunk on the player's own hull.
        let landings: Set<FeedbackEvent> = [.miss, .nearMiss, .hit, .hitOwn, .sunk, .sunkOwn]
        let theirLandingAt = try #require(feedback.events.lastIndex { landings.contains($0) })
        #expect(myLandingAt < incomingAt, "the telegraph comes after the player's landing")
        #expect(incomingAt < whistleAt)
        #expect(whistleAt < theirLandingAt, "and before the enemy's")
        #expect(controller.telegraph == nil)
        #expect(controller.latestEnemyShot == theirs.coordinate)
    }

    @Test func theTurnStingFollowsTheEnemysLanding() async throws {
        let (_, feedback, match, controller) = try makeSoloBattle()
        controller.beats.turnSting = 60
        await controller.load()
        controller.tapTarget(try water(in: match))
        await controller.fire()

        #expect(controller.impacts.contains { $0.board == .home })
        #expect(controller.isMyTurn, "the sting never holds up input")
        #expect(controller.turnStings == 0)
        #expect(!feedback.events.contains(.turnSting))

        controller.skipSequences()
        #expect(controller.turnStings == 1)
        #expect(feedback.events.last == .turnSting)
        #expect(controller.isMyTurn)
    }

    @Test func hitStreaksAreCounted() async throws {
        let (_, feedback, match, controller) = try makeSoloBattle()
        await controller.load()
        let boats = match.battle.fleet(of: ComputerMatch.computer)

        for (index, boat) in boats.prefix(3).enumerated() {
            controller.tapTarget(boat.origin)
            await controller.fire()
            #expect(controller.hitStreak == index + 1)
        }
        #expect(feedback.events.filter { $0 == .streak }.count == 1, "the streak is celebrated at three")

        controller.tapTarget(try water(in: match))
        await controller.fire()
        #expect(controller.hitStreak == 0, "a miss ends the streak")
        #expect(feedback.events.filter { $0 == .streak }.count == 1)
        #expect(!controller.isEnemyOnLastShip)
        #expect(!feedback.events.contains(.lastShip))
    }

    @Test func theFinaleSetsTheSceneThenShowsTheOutcome() async throws {
        let (app, feedback, fresh, controller) = try makeSoloBattle()
        // Four of the five boats are already down.
        var match = fresh
        let boats = match.battle.fleet(of: ComputerMatch.computer)
        for boat in boats.prefix(4) {
            try match.fire(at: boat.origin)
            match.playComputerTurn()
        }
        app.solo.update(match)
        controller.beats.finaleCard = 0.3
        controller.viewDidAppear()
        #expect(controller.isEnemyOnLastShip)
        #expect(!feedback.events.contains(.lastShip), "opening a game doesn't replay the news")

        let last = try #require(boats.last)
        controller.tapTarget(last.origin)
        await controller.fire()

        let finale = try #require(controller.finale)
        #expect(finale.board == .target)
        #expect(finale.coordinate == last.origin)
        #expect(finale.didWin)
        #expect(controller.impacts.last?.isFinal == true)
        #expect(feedback.events.contains(.finalBlow))
        #expect(!feedback.events.contains(.sunk), "the final blow replaces the landing event")
        #expect(feedback.events.contains(.victory))
        #expect(feedback.events.contains(.stamp))
        #expect(controller.phase == .finished)
        #expect(controller.headline == "Victory")
        #expect(controller.displayedTurn == nil)
        #expect(!controller.isEnemyOnLastShip)
        // Effect time on the enemy's waters: a long stop, then slow motion.
        let clock = controller.targetClock
        let slowed = clock.time(at: finale.start.addingTimeInterval(Timing.finalHitStop + Timing.finalSlowMotion)) - clock.time(at: finale.start)
        #expect(abs(slowed - Timing.finalSlowMotion * Timing.finalTimeScale) < 0.001)

        try await eventually { controller.showsOutcome }
        #expect(controller.showsOutcome)
        #expect(Date() >= finale.start.addingTimeInterval(0.3 - 0.02), "the board finishes its beat before the card")
        #expect(controller.finale != nil, "the board keeps its end state under the card")
        #expect(app.solo.record.wins[.easy] == 1)
    }

    @Test func skippingTheFinaleShowsTheOutcomeAtOnce() async throws {
        let (app, _, fresh, controller) = try makeSoloBattle()
        var match = fresh
        let boats = match.battle.fleet(of: ComputerMatch.computer)
        for boat in boats.prefix(4) {
            try match.fire(at: boat.origin)
            match.playComputerTurn()
        }
        app.solo.update(match)
        controller.beats.finaleCard = 60
        controller.beats.stampHold = 60
        controller.viewDidAppear()

        controller.tapTarget(try #require(boats.last).origin)
        await controller.fire()
        #expect(controller.finale != nil)
        #expect(!controller.showsOutcome)
        #expect(!controller.stamps.isEmpty)

        controller.skipFinale()
        #expect(controller.showsOutcome)
        #expect(controller.finale == nil)
        #expect(controller.stamps.isEmpty, "every pending beat has run")
        #expect(controller.impacts.isEmpty)
    }

    @Test func theOpponentsFinalShotIsAFinaleOnTheHomeBoard() async throws {
        let (app, feedback) = try makeSignedInTestApp()
        let summary = makeSummary(status: .active, you: .one, turn: .one)
        let fleet = Rules.quick.randomFleet()
        let lastBoat = try #require(fleet.first)
        let opened = [Move(player: .one, target: Coordinate("A1")!, result: .miss)]
        app.online.apply(GameDetail(summary: summary, yourFleet: fleet, knownOpponentShips: [], moves: opened))
        let controller = BattleController(route: .online(summary.id), app: app)
        controller.beats = .instant
        controller.beats.finaleCard = 0.3
        controller.beats.sinking = 60
        controller.impactDuration = .seconds(60)
        controller.seenMoveCounts = SeenMoveCounts(defaults: try #require(UserDefaults(suiteName: "SeenMoves-\(UUID().uuidString)")))
        controller.viewDidAppear()
        #expect(controller.isMyTurn)

        // The opponent's shot sinks the player's last boat, and the server says the game is over.
        var ended = summary
        ended.status = .finished
        ended.outcome = Outcome(winner: .two, reason: .fleetDestroyed)
        let finalShot = Move(player: .two, target: lastBoat.origin, result: .sunk(lastBoat.kind))
        app.online.apply(GameDetail(summary: ended, yourFleet: fleet, knownOpponentShips: [], moves: opened + [finalShot]))
        controller.syncMoves()

        let finale = try #require(controller.finale)
        #expect(finale.board == .home)
        #expect(finale.coordinate == lastBoat.origin)
        #expect(!finale.didWin)
        #expect(feedback.events.contains(.incoming), "it was telegraphed")
        #expect(feedback.events.contains(.finalBlow))
        #expect(!feedback.events.contains(.sunk))
        #expect(feedback.events.contains(.defeat))
        #expect(controller.sinkings.first?.ship == lastBoat)
        #expect(controller.impacts.last?.isFinal == true)
        #expect(controller.telegraph == nil)
        #expect(controller.phase == .finished)
        #expect(controller.headline == "Defeat")
        #expect(controller.turnStings == 0, "no turn comes back")
        #expect(controller.homeClock.isFrozen(at: finale.start.addingTimeInterval(0.1)))
        try await eventually { controller.showsOutcome }
        #expect(controller.showsOutcome)
        #expect(Date() >= finale.start.addingTimeInterval(0.3 - 0.02))
        controller.viewDidDisappear()
    }

    @Test func leavingMidFlightSettlesTheStateWithoutFeedback() async throws {
        let (app, feedback, match, controller) = try makeSoloBattle()
        controller.beats.shellFlight = 60
        await controller.load()
        let boat = try #require(match.battle.fleet(of: ComputerMatch.computer).first)
        controller.tapTarget(boat.origin)
        let firing = Task { await controller.fire() }
        try await eventually { controller.shells.count == 1 }

        controller.viewDidDisappear()
        await firing.value

        #expect(controller.shells.isEmpty)
        #expect(controller.impacts.isEmpty)
        #expect(controller.sinkings.isEmpty)
        #expect(!controller.isSubmitting)
        #expect(!controller.isComputerThinking)
        #expect(app.solo.match(match.id)?.battle.moves.count == 1, "the shot was made")
        #expect(controller.latestOwnShot == boat.origin)
        #expect(controller.hitStreak == 1, "the state is right")
        #expect(controller.hitsLanded == 0, "but nothing reacted on screen")
        #expect(controller.spokenAnnouncement == nil)
        #expect(feedback.events == [.aim, .fire])

        // Back on screen, the computer takes the turn it was holding.
        controller.viewDidAppear()
        try await eventually { app.solo.match(match.id)?.battle.moves.count == 2 }
        #expect(feedback.events.contains(.incoming))
        #expect(controller.isMyTurn)
    }

    @Test func skippingLandsEverythingNow() async throws {
        let (app, feedback, match, controller) = try makeSoloBattle(computerPause: 60_000...60_000)
        controller.beats.shellFlight = 60
        await controller.load()
        controller.tapTarget(try water(in: match))
        let firing = Task { await controller.fire() }
        try await eventually { controller.shells.count == 1 }

        controller.skipSequences()
        await firing.value
        #expect(controller.shells.isEmpty)
        #expect(!controller.isSubmitting)
        #expect(feedback.events.contains(.miss), "the shell landed, with its feedback")
        #expect(feedback.events.contains(.incoming), "and the computer's reply followed at once")
        #expect(app.solo.match(match.id)?.battle.moves.count == 2)
        #expect(!controller.isComputerThinking)
        #expect(controller.impacts.isEmpty, "what was animating is cleared")
        #expect(controller.telegraph == nil)
        #expect(controller.isMyTurn)
    }

    @Test func theComputersTelegraphedTargetIsTheOneItFiresAt() throws {
        for difficulty in Difficulty.allCases {
            var match = try ComputerMatch(mode: .classic, difficulty: difficulty, playerFleet: Rules.classic.randomFleet())
            try match.fire(at: Coordinate("A1")!)
            var generator = SeededRandomNumberGenerator(seed: 2026)
            let replay = generator
            let target = match.opponent.chooseTarget(with: match.battle.intel(for: ComputerMatch.computer), using: &generator)
            var again = replay
            let move = match.playComputerTurn(using: &again)
            #expect(move?.target == target, "\(difficulty) picks the same square from the same seed")
        }
    }

    @Test func aNewGameOpensWithBattleStations() async throws {
        let (_, _, _, controller) = try makeSoloBattle()
        controller.beats.opening = 0.1
        controller.viewDidAppear()

        let opening = try #require(controller.opening)
        #expect(!isMatchFound(opening), "against the computer there is no one to find")
        #expect(!controller.isMyTurn, "input is closed during the opening")
        controller.tapTarget(Coordinate("A1")!)
        #expect(controller.aimed == nil)
        #expect(controller.headline == "Your turn")

        try await eventually { controller.opening == nil }
        #expect(controller.isMyTurn)
        controller.tapTarget(Coordinate("A1")!)
        #expect(controller.aimed == Coordinate("A1"))
    }

    @Test func theOpeningCanBeSkipped() async throws {
        let (_, _, _, controller) = try makeSoloBattle()
        controller.beats.opening = 60
        controller.viewDidAppear()
        #expect(controller.opening != nil)
        controller.skipOpening()
        #expect(controller.opening == nil)
        #expect(controller.isMyTurn)
        // A skipped opening doesn't come back.
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.opening == nil)
    }

    @Test func anOpponentFoundOnlineOpensWithMatchFound() async throws {
        let (app, _) = try makeSignedInTestApp()
        let id = UUID()
        let fleet = Rules.quick.randomFleet()
        func detail(_ status: GameStatus, opponent: PlayerSummary?, turn: Player?) -> GameDetail {
            let summary = GameSummary(
                id: id, mode: .quick, status: status, you: .one, opponent: opponent, turn: turn, outcome: nil,
                yourShipsRemaining: 5, opponentShipsRemaining: 5, createdAt: Date(), updatedAt: Date(), turnDeadline: nil
            )
            return GameDetail(summary: summary, yourFleet: fleet, knownOpponentShips: [], moves: [])
        }
        app.online.apply(detail(.matchmaking, opponent: nil, turn: nil))
        let controller = BattleController(route: .online(id), app: app)
        controller.beats = .instant
        controller.beats.matchFound = 60
        controller.viewDidAppear()
        #expect(controller.phase == .waitingForOpponent)
        #expect(controller.opening == nil)

        // The server finds someone. The controller notices on its own.
        app.online.apply(detail(.active, opponent: PlayerSummary(id: UUID(), username: "rival", rating: 1000), turn: .one))
        try await eventually { controller.opening != nil }
        #expect(isMatchFound(controller.opening))
        #expect(controller.phase == .battle)
        #expect(!controller.isMyTurn)

        controller.skipOpening()
        #expect(controller.opening == nil)
        #expect(controller.isMyTurn)
        #expect(controller.displayedTurn == .one)
        controller.viewDidDisappear()
    }

    @Test func catchUpReplaysOnlyTheOpponentsUnseenShots() async throws {
        let (app, feedback) = try makeSignedInTestApp()
        let seen = SeenMoveCounts(defaults: try #require(UserDefaults(suiteName: "SeenMoves-\(UUID().uuidString)")))
        let summary = makeSummary(status: .active, you: .one, turn: .one)
        let fleet = Rules.classic.randomFleet()
        let early = [
            Move(player: .one, target: Coordinate("A1")!, result: .miss),
            Move(player: .two, target: Coordinate("B2")!, result: .miss),
        ]
        app.online.apply(GameDetail(summary: summary, yourFleet: fleet, knownOpponentShips: [], moves: early))

        // The first look only takes note of the history.
        let before = BattleController(route: .online(summary.id), app: app)
        before.beats = .instant
        before.impactDuration = .seconds(60)
        before.seenMoveCounts = seen
        before.viewDidAppear()
        #expect(before.impacts.isEmpty)
        #expect(!before.isCatchingUp)
        #expect(seen.count(of: summary.id) == 2)
        before.viewDidDisappear()

        // Shots are exchanged while the player is away (theirs made on another device).
        let later = early + [
            Move(player: .one, target: Coordinate("C3")!, result: .miss),
            Move(player: .two, target: Coordinate("D4")!, result: .miss),
            Move(player: .one, target: Coordinate("E5")!, result: .miss),
            Move(player: .two, target: Coordinate("F6")!, result: .miss),
        ]
        app.online.apply(GameDetail(summary: summary, yourFleet: fleet, knownOpponentShips: [], moves: later))

        let returning = BattleController(route: .online(summary.id), app: app)
        returning.beats = .instant
        returning.impactDuration = .seconds(60)
        returning.seenMoveCounts = seen
        returning.viewDidAppear()
        try await eventually { !returning.isCatchingUp }
        #expect(returning.impacts.map(\.board) == [.home, .home])
        #expect(returning.impacts.map(\.coordinate) == [Coordinate("D4"), Coordinate("F6")])
        #expect(feedback.events.filter { $0 == .incoming }.count == 2)
        #expect(feedback.events.filter { $0 == .miss }.count == 2)
        #expect(returning.latestEnemyShot == Coordinate("F6"))
        #expect(returning.latestOwnShot == nil)
        #expect(returning.displayedTurn == .one)
        #expect(returning.isMyTurn)
        #expect(returning.turnStings == 1, "the replay hands the turn back")
        #expect(seen.count(of: summary.id) == 6)
        returning.viewDidDisappear()

        // Nothing is left to replay.
        let again = BattleController(route: .online(summary.id), app: app)
        again.beats = .instant
        again.impactDuration = .seconds(60)
        again.seenMoveCounts = seen
        again.viewDidAppear()
        #expect(again.impacts.isEmpty)
        #expect(feedback.events.filter { $0 == .incoming }.count == 2)
        again.viewDidDisappear()
    }

    @Test func seenMoveCountsOnlyEverGrow() throws {
        let defaults = try #require(UserDefaults(suiteName: "SeenMoves-\(UUID().uuidString)"))
        let seen = SeenMoveCounts(defaults: defaults)
        let game = UUID()
        #expect(seen.count(of: game) == nil)
        seen.mark(game, count: 4)
        seen.mark(game, count: 2)
        #expect(seen.count(of: game) == 4)
        seen.mark(game, count: 7)
        #expect(SeenMoveCounts(defaults: defaults).count(of: game) == 7)
        #expect(seen.count(of: UUID()) == nil)
    }
}
