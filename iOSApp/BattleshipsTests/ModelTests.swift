import BattleshipAPI
import BattleshipCore
import Foundation
import Testing
@testable import Battleships

@MainActor
@Suite("Fleet placement")
struct FleetPlacementTests {
    let fleet: [ShipPlacement] = [
        ShipPlacement(kind: .carrier, origin: Coordinate("A1")!, orientation: .horizontal),
        ShipPlacement(kind: .battleship, origin: Coordinate("C1")!, orientation: .horizontal),
        ShipPlacement(kind: .cruiser, origin: Coordinate("E1")!, orientation: .horizontal),
        ShipPlacement(kind: .submarine, origin: Coordinate("G1")!, orientation: .horizontal),
        ShipPlacement(kind: .destroyer, origin: Coordinate("J9")!, orientation: .horizontal),
    ]

    @Test func startsWithALegalFleet() {
        for mode in GameMode.allCases {
            let model = FleetPlacementModel(rules: mode.rules)
            #expect(model.isValid)
            #expect(model.ships.count == mode.rules.fleet.count)
        }
    }

    @Test func ignoresAnIllegalStartingFleet() {
        let model = FleetPlacementModel(rules: .classic, ships: Array(fleet.prefix(2)))
        #expect(model.isValid)
        #expect(model.ships.count == 5)
    }

    @Test func movesOnlyIntoOpenWater() {
        let model = FleetPlacementModel(rules: .classic, ships: fleet)
        #expect(model.move(1, to: Coordinate("B1")!))
        #expect(model.ships[1].origin == Coordinate("B1"))
        #expect(!model.move(1, to: Coordinate("A2")!), "would overlap the carrier")
        #expect(!model.move(0, to: Coordinate("A7")!), "would run off the board")
        #expect(model.ships[0].origin == Coordinate("A1"))
        #expect(model.isValid)
    }

    @Test func rotationSlidesBackOntoTheBoard() {
        let model = FleetPlacementModel(rules: .classic, ships: fleet)
        // The destroyer at J9–J10 can't point down from row J, so it slides up to I9–J9.
        #expect(model.rotate(4))
        #expect(model.ships[4] == ShipPlacement(kind: .destroyer, origin: Coordinate("I9")!, orientation: .vertical))
        #expect(model.isValid)
    }

    @Test func rotationIsRefusedWhenThereIsNoRoom() {
        let crowded: [ShipPlacement] = [
            ShipPlacement(kind: .carrier, origin: Coordinate("A1")!, orientation: .horizontal),
            ShipPlacement(kind: .battleship, origin: Coordinate("B1")!, orientation: .horizontal),
            ShipPlacement(kind: .cruiser, origin: Coordinate("C1")!, orientation: .horizontal),
            ShipPlacement(kind: .submarine, origin: Coordinate("D1")!, orientation: .horizontal),
            ShipPlacement(kind: .destroyer, origin: Coordinate("E1")!, orientation: .horizontal),
        ]
        let model = FleetPlacementModel(rules: .classic, ships: crowded)
        #expect(!model.rotate(1), "every vertical position through B1 hits another ship")
        #expect(model.ships == crowded)
    }

    @Test func nudgesForAccessibility() {
        let model = FleetPlacementModel(rules: .classic, ships: fleet)
        #expect(model.nudge(4, rows: -1))
        #expect(model.ships[4].origin == Coordinate("I9"))
        #expect(!model.nudge(4, columns: 1), "already touching the right edge")
    }

    @Test func singleCellBoatsDoNotRotate() {
        let model = FleetPlacementModel(rules: .quick)
        #expect(!model.rotate(0))
    }
}

@Suite("Lobby")
struct LobbyTests {
    @Test func sortsGamesIntoSections() {
        let now = Date()
        let challenge = makeSummary(status: .invited, you: .two, updatedAt: now)
        let sentChallenge = makeSummary(status: .invited, you: .one, updatedAt: now)
        let myMove = makeSummary(status: .active, you: .two, turn: .two, updatedAt: now.addingTimeInterval(-60))
        let theirMove = makeSummary(status: .active, you: .one, turn: .two, updatedAt: now)
        let searching = makeSummary(status: .matchmaking, opponent: nil)
        let won = makeSummary(status: .finished, outcome: Outcome(winner: .one, reason: .fleetDestroyed))

        let groups = Lobby.groups(online: [won, searching, theirMove, myMove, sentChallenge, challenge], solo: [])
        #expect(groups.map(\.section) == [.challenges, .yourTurn, .waiting, .finished])
        #expect(groups[0].entries.map(\.id) == [challenge.id])
        #expect(groups[1].entries.map(\.id) == [myMove.id])
        #expect(Set(groups[2].entries.map(\.id)) == [sentChallenge.id, theirMove.id, searching.id])
        #expect(groups[3].entries.first?.didWin == true)
    }

    @Test func gamesAgainstTheComputerAreAlwaysYourMoveUntilOver() throws {
        var match = try ComputerMatch(mode: .quick, difficulty: .easy, playerFleet: Rules.quick.randomFleet())
        #expect(LobbyEntry.solo(match).section == .yourTurn)
        try match.resign()
        #expect(LobbyEntry.solo(match).section == .finished)
        #expect(LobbyEntry.solo(match).status == "Lost · resigned")
    }

    @Test func describesOnlineGames() {
        #expect(LobbyEntry.online(makeSummary(status: .matchmaking, opponent: nil)).status == "Looking for an opponent…")
        #expect(LobbyEntry.online(makeSummary(status: .invited, you: .two)).status == "Challenged you")
        #expect(LobbyEntry.online(makeSummary(status: .active, turn: .one)).status == "Your move · 5 vs 5 ships")
        #expect(LobbyEntry.online(makeSummary(status: .active, turn: .two)).status == "Their move · 5 vs 5 ships")
        #expect(LobbyEntry.online(makeSummary(status: .finished, you: .two, outcome: Outcome(winner: .two, reason: .resignation))).status
            == "Won · opponent resigned")
    }

    @Test func lobbyCountsDownTheLastDayToMove() {
        let now = Date()
        let relaxed = makeSummary(status: .active, turn: .one, turnDeadline: now.addingTimeInterval(50 * 3600))
        #expect(LobbyEntry.online(relaxed).status(at: now) == "Your move · 5 vs 5 ships")
        let urgent = makeSummary(status: .active, turn: .one, turnDeadline: now.addingTimeInterval(5 * 3600 + 120))
        #expect(LobbyEntry.online(urgent).status(at: now) == "Your move · 5h left")
        let lastMinutes = makeSummary(status: .active, turn: .one, turnDeadline: now.addingTimeInterval(40 * 60 + 5))
        #expect(LobbyEntry.online(lastMinutes).status(at: now) == "Your move · 40m left")
        let theirsExpired = makeSummary(status: .active, turn: .two, turnDeadline: now.addingTimeInterval(-60))
        #expect(LobbyEntry.online(theirsExpired).status(at: now) == "Time's up · claim the win")
    }

    @Test func showsOnlyRecentFinishedGames() {
        let finished = (0..<30).map { index in
            makeSummary(status: .finished, outcome: Outcome(winner: .one, reason: .fleetDestroyed), updatedAt: Date(timeIntervalSince1970: Double(index)))
        }
        let groups = Lobby.groups(online: finished, solo: [])
        #expect(groups.first?.entries.count == Lobby.finishedGamesShown)
        #expect(groups.first?.entries.first?.updatedAt == Date(timeIntervalSince1970: 29))
    }
}

@Suite("Online games")
struct OnlineGamesTests {
    func detail(status: GameStatus, moves: Int) -> GameDetail {
        let shots = (0..<moves).map { index in
            Move(player: index.isMultiple(of: 2) ? .one : .two, target: Coordinate(row: index / 10, column: index % 10), result: .miss)
        }
        return GameDetail(summary: makeSummary(status: status), yourFleet: [], knownOpponentShips: [], moves: shots)
    }

    @Test func olderSnapshotsAreIgnored() {
        #expect(OnlineGamesStore.isStale(detail(status: .active, moves: 3), comparedTo: detail(status: .active, moves: 4)))
        #expect(!OnlineGamesStore.isStale(detail(status: .active, moves: 5), comparedTo: detail(status: .active, moves: 4)))
        #expect(OnlineGamesStore.isStale(detail(status: .invited, moves: 0), comparedTo: detail(status: .active, moves: 0)))
        #expect(!OnlineGamesStore.isStale(detail(status: .finished, moves: 4), comparedTo: detail(status: .active, moves: 4)))
        #expect(!OnlineGamesStore.isStale(detail(status: .active, moves: 4), comparedTo: detail(status: .active, moves: 4)))
    }

    @MainActor
    @Test func applyingUpdatesTheLobbyAndKeepsTheNewest() {
        let (app, _) = makeTestApp()
        var newer = detail(status: .active, moves: 2)
        var older = newer
        older.moves.removeLast()

        app.online.apply(newer)
        #expect(app.online.summaries.map(\.id) == [newer.id])
        app.online.apply(older)
        #expect(app.online.details[newer.id]?.moves.count == 2, "a late, older response doesn't roll the game back")

        newer.summary.status = .finished
        app.online.apply(newer)
        #expect(app.online.summary(for: newer.id)?.status == .finished)

        app.online.remove(newer.id, reason: .cancelled)
        #expect(app.online.summaries.isEmpty)
        #expect(app.online.removals[newer.id] == .cancelled)
    }
}

@MainActor
@Suite("Games against the computer")
struct SoloGamesTests {
    @Test func gamesSurviveARelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SoloGamesStore(directory: directory)
        var match = try store.start(mode: .classic, difficulty: .hard, fleet: Rules.classic.randomFleet())
        try match.fire(at: Coordinate("E5")!)
        store.update(match)

        let relaunched = SoloGamesStore(directory: directory)
        #expect(relaunched.matches.map(\.id) == [match.id])
        #expect(relaunched.match(match.id)?.battle == match.battle)
    }

    @Test func finishingAGameUpdatesTheRecordOnce() throws {
        let store = SoloGamesStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var match = try store.start(mode: .quick, difficulty: .medium, fleet: Rules.quick.randomFleet())
        try match.resign()
        store.update(match)
        store.update(match)
        #expect(store.record.losses[.medium] == 1)
        #expect(store.record.totalWins == 0)

        store.delete(match.id)
        #expect(store.matches.isEmpty)
        #expect(store.record.losses[.medium] == 1, "deleting a game keeps the record")
    }

    @Test func keepsALimitedHistory() throws {
        let store = SoloGamesStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for _ in 0..<(SoloGamesStore.finishedGamesKept + 5) {
            var match = try store.start(mode: .quick, difficulty: .easy, fleet: Rules.quick.randomFleet())
            try match.resign()
            store.update(match)
        }
        let unfinished = try store.start(mode: .quick, difficulty: .easy, fleet: Rules.quick.randomFleet())
        #expect(store.matches.filter(\.isOver).count == SoloGamesStore.finishedGamesKept)
        #expect(store.match(unfinished.id) != nil)
    }
}

@Suite("Settings and layout")
struct SettingsAndLayoutTests {
    @Test(arguments: [
        ("https://battleships.example.com", "https://battleships.example.com"),
        ("  http://my-mac.local:8080/ ", "http://my-mac.local:8080"),
        ("HTTPS://Example.com/api//", "https://Example.com/api"),
    ])
    func acceptsServerAddresses(input: String, expected: String) {
        #expect(AppSettings.validatedServerURL(input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "battleships.example.com", "ftp://example.com", "http://", "not a url"])
    func rejectsBadServerAddresses(input: String) {
        #expect(AppSettings.validatedServerURL(input) == nil)
    }

    @MainActor
    @Test func soundIsOnUntilTurnedOff() throws {
        let defaults = try #require(UserDefaults(suiteName: "SoundTest-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        #expect(settings.soundEnabled)
        settings.soundEnabled = false
        #expect(!AppSettings(defaults: defaults).soundEnabled)
    }

    @MainActor
    @Test func remembersTheWelcomeScreen() throws {
        let defaults = try #require(UserDefaults(suiteName: "WelcomeTest-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.hasSeenWelcome)
        settings.hasSeenWelcome = true
        #expect(AppSettings(defaults: defaults).hasSeenWelcome)
    }

    @Test func boardGeometryMapsPointsToCells() {
        let geometry = BoardGeometry(boardSize: 10, side: 330, showsLabels: true)
        #expect(geometry.gutter == 18.15)
        let b7 = Coordinate("B7")!
        let center = geometry.center(of: b7)
        #expect(geometry.coordinate(at: center) == b7)
        #expect(geometry.coordinate(at: CGPoint(x: 5, y: 5)) == nil, "the label gutter isn't a cell")
        #expect(geometry.coordinate(at: CGPoint(x: 329.9, y: 329.9)) == Coordinate("J10"))

        let carrier = ShipPlacement(kind: .carrier, origin: Coordinate("A1")!, orientation: .vertical)
        let rect = geometry.rect(for: carrier)
        #expect(abs(rect.height - geometry.cell * 5) < 0.001)
        #expect(abs(rect.width - geometry.cell) < 0.001)
    }
}

@Suite("Sound effects")
struct SoundEffectTests {
    @Test(arguments: FeedbackEvent.allCases)
    func everyEventHasAWellFormedSound(event: FeedbackEvent) {
        let samples = SoundSynthesis.samples(for: event)
        #expect(!samples.isEmpty)
        #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect(samples.contains { abs($0) > 0.05 })
    }

    @Test func shellsLandAfterTheirFlight() {
        let flight = SoundSynthesis.frames(SoundSynthesis.flightTime)
        for event in [FeedbackEvent.hit, .miss, .sunk] {
            let samples = SoundSynthesis.samples(for: event)
            #expect(samples.prefix(flight).allSatisfy { $0 == 0 }, "silent while the shell is in the air")
            #expect(samples.dropFirst(flight).prefix(4_000).contains { abs($0) > 0.1 }, "then it lands")
        }
    }
}
