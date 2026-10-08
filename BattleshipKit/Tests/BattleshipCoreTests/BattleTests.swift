import BattleshipCore
import Foundation
import Testing

/// Player one: ships along the top-left. Player two: ships along the bottom-right.
func makeClassicBattle() throws -> Battle {
    let fleetOne = RulesTests.classicFleet
    let fleetTwo: [ShipPlacement] = [
        ShipPlacement(kind: .carrier, origin: Coordinate("J6")!, orientation: .horizontal),
        ShipPlacement(kind: .battleship, origin: Coordinate("I7")!, orientation: .horizontal),
        ShipPlacement(kind: .cruiser, origin: Coordinate("H8")!, orientation: .horizontal),
        ShipPlacement(kind: .submarine, origin: Coordinate("G8")!, orientation: .horizontal),
        ShipPlacement(kind: .destroyer, origin: Coordinate("F9")!, orientation: .horizontal),
    ]
    return try Battle(mode: .classic, fleetOne: fleetOne, fleetTwo: fleetTwo)
}

@Suite("Battles")
struct BattleTests {
    @Test func playersAlternateStartingWithPlayerOne() throws {
        var battle = try makeClassicBattle()
        #expect(battle.turn == .one)
        try battle.fire(.one, at: Coordinate("A1")!)
        #expect(battle.turn == .two)
        #expect(throws: BattleError.notYourTurn) { try battle.fire(.one, at: Coordinate("A2")!) }
        try battle.fire(.two, at: Coordinate("A1")!)
        #expect(battle.turn == .one)
    }

    @Test func aHitDoesNotGrantAnExtraShot() throws {
        var battle = try makeClassicBattle()
        let move = try battle.fire(.one, at: Coordinate("J6")!)
        #expect(move.result == .hit)
        #expect(battle.turn == .two)
    }

    @Test func rejectsIllegalShots() throws {
        var battle = try makeClassicBattle()
        #expect(throws: BattleError.outOfBounds(Coordinate("K1")!)) { try battle.fire(.one, at: Coordinate("K1")!) }
        try battle.fire(.one, at: Coordinate("C3")!)
        try battle.fire(.two, at: Coordinate("C3")!)
        #expect(throws: BattleError.alreadyTargeted(Coordinate("C3")!)) { try battle.fire(.one, at: Coordinate("C3")!) }
        #expect(battle.moves.count == 2, "rejected shots are not recorded")
    }

    @Test func reportsMissHitAndSunk() throws {
        var battle = try makeClassicBattle()
        #expect(try battle.fire(.one, at: Coordinate("A1")!).result == .miss)
        try battle.fire(.two, at: Coordinate("J1")!)
        #expect(try battle.fire(.one, at: Coordinate("F9")!).result == .hit)
        try battle.fire(.two, at: Coordinate("J2")!)
        #expect(try battle.fire(.one, at: Coordinate("F10")!).result == .sunk(.destroyer))
        #expect(battle.sunkShips(of: .two).map(\.kind) == [.destroyer])
        #expect(battle.remainingShips(of: .two) == 4)
    }

    @Test func sinkingTheWholeFleetWins() throws {
        var battle = try makeClassicBattle()
        let targets = battle.fleet(of: .two).flatMap(\.cells)
        var misses = Rules.classic.allCoordinates.filter { cell in !targets.contains(cell) }.makeIterator()

        for (index, target) in targets.enumerated() {
            let move = try battle.fire(.one, at: target)
            if index < targets.count - 1 {
                #expect(battle.outcome == nil)
                try battle.fire(.two, at: misses.next()!)
            } else {
                #expect(move.result.isHit)
            }
        }
        #expect(battle.outcome == Outcome(winner: .one, reason: .fleetDestroyed))
        #expect(battle.turn == nil)
        #expect(throws: BattleError.gameOver) { try battle.fire(.two, at: Coordinate("J10")!) }
        #expect(throws: BattleError.gameOver) { try battle.resign(.two) }
    }

    @Test func resigningHandsTheWinToTheOpponent() throws {
        var battle = try makeClassicBattle()
        try battle.resign(.one)
        #expect(battle.outcome == Outcome(winner: .two, reason: .resignation))
        #expect(battle.isOver)
    }

    @Test func rejectsIllegalFleets() {
        #expect(throws: FleetError.self) {
            try Battle(mode: .quick, fleetOne: RulesTests.classicFleet, fleetTwo: Rules.quick.randomFleet())
        }
    }

    @Test func replayRestoresAndVerifiesHistory() throws {
        var battle = try makeClassicBattle()
        for target in ["F9", "A1", "F10", "B2", "A5"] {
            try battle.fire(battle.turn!, at: Coordinate(target)!)
        }
        let restored = try Battle(
            mode: .classic,
            fleetOne: battle.fleet(of: .one),
            fleetTwo: battle.fleet(of: .two),
            replaying: battle.moves
        )
        #expect(restored == battle)

        var tampered = battle.moves
        tampered[0] = Move(player: .one, target: Coordinate("F9")!, result: .miss)
        #expect(throws: BattleError.self) {
            try Battle(mode: .classic, fleetOne: battle.fleet(of: .one), fleetTwo: battle.fleet(of: .two), replaying: tampered)
        }
    }

    @Test func codableRoundTripValidatesState() throws {
        var battle = try makeClassicBattle()
        try battle.fire(.one, at: Coordinate("J6")!)
        try battle.resign(.two)

        let data = try JSONEncoder().encode(battle)
        #expect(try JSONDecoder().decode(Battle.self, from: data) == battle)

        // A hand-edited save with an impossible result fails to load rather than corrupting the game.
        let forged = String(decoding: data, as: UTF8.self).replacingOccurrences(of: #""result":"hit""#, with: #""result":"miss""#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Battle.self, from: Data(forged.utf8)) }
    }
}

@Suite("Perspectives")
struct PerspectiveTests {
    @Test func hidesEnemyShipsUntilSunk() throws {
        var battle = try makeClassicBattle()
        try battle.fire(.one, at: Coordinate("F9")!)
        try battle.fire(.two, at: Coordinate("A1")!)

        let view = battle.perspective(for: .one)
        #expect(view.knownEnemyShips.isEmpty)
        #expect(view.myFleet == battle.fleet(of: .one))
        #expect(view.targetMark(at: Coordinate("F9")!) == .hit)
        #expect(view.homeMark(at: Coordinate("A1")!) == .hit)
        #expect(view.knownEnemyShip(at: Coordinate("F10")!) == nil)

        try battle.fire(.one, at: Coordinate("F10")!)
        let afterSinking = battle.perspective(for: .one)
        #expect(afterSinking.knownEnemyShips.map(\.kind) == [.destroyer])
        #expect(afterSinking.targetMark(at: Coordinate("F9")!) == .sunk)
        #expect(afterSinking.targetMark(at: Coordinate("F10")!) == .sunk)
        #expect(afterSinking.enemyShipsRemaining == 4)
        #expect(afterSinking.isSunk(afterSinking.knownEnemyShips[0]))
    }

    @Test func revealsEverythingOnceOver() throws {
        var battle = try makeClassicBattle()
        try battle.resign(.two)
        let view = battle.perspective(for: .one)
        #expect(view.knownEnemyShips == battle.fleet(of: .two))
        #expect(view.didWin == true)
        #expect(battle.perspective(for: .two).didWin == false)
    }

    @Test func tracksTurnsAndStats() throws {
        var battle = try makeClassicBattle()
        try battle.fire(.one, at: Coordinate("F9")!) // hit
        try battle.fire(.two, at: Coordinate("J10")!) // miss
        try battle.fire(.one, at: Coordinate("A10")!) // miss

        let mine = battle.perspective(for: .one)
        #expect(!mine.isMyTurn)
        #expect(mine.myStats == ShotStats(shotsFired: 2, hits: 1))
        #expect(mine.myStats.accuracy == 0.5)
        #expect(mine.enemyStats == ShotStats(shotsFired: 1, hits: 0))
        #expect(mine.homeMark(at: Coordinate("J10")!) == .miss)
        #expect(!mine.canTarget(Coordinate("B5")!))

        let theirs = battle.perspective(for: .two)
        #expect(theirs.isMyTurn)
        #expect(theirs.canTarget(Coordinate("B5")!))
        #expect(!theirs.canTarget(Coordinate("J10")!))
        #expect(theirs.myShipsRemaining == 5)
    }
}
