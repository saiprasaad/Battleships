import BattleshipCore
import Foundation
import Testing

@Suite("Computer opponent")
struct ComputerOpponentTests {
    /// Lets the computer fire at a random fleet until it sinks everything; returns the number of shots.
    static func shotsToWin(_ difficulty: Difficulty, mode: GameMode, seed: UInt64) throws -> Int {
        var generator = SeededRandomNumberGenerator(seed: seed)
        let ai = ComputerOpponent(difficulty: difficulty)
        let fleet = mode.rules.randomFleet(using: &generator)
        var shots: [Move] = []
        var hits = Set<Coordinate>()

        while true {
            let sunk = fleet.filter { $0.cells.allSatisfy(hits.contains) }
            if sunk.count == fleet.count { return shots.count }

            let intel = TargetingIntel(rules: mode.rules, shots: shots, sunkShips: sunk)
            let target = ai.chooseTarget(with: intel, using: &generator)
            #expect(mode.rules.contains(target))
            #expect(!intel.targeted.contains(target), "never fires at the same cell twice")

            let result: ShotResult
            if let ship = fleet.first(where: { $0.contains(target) }) {
                hits.insert(target)
                result = ship.cells.allSatisfy(hits.contains) ? .sunk(ship.kind) : .hit
            } else {
                result = .miss
            }
            shots.append(Move(player: .one, target: target, result: result))
            try #require(shots.count <= mode.rules.boardSize * mode.rules.boardSize)
        }
    }

    @Test(arguments: Difficulty.allCases, GameMode.allCases)
    func alwaysFinishesTheGame(difficulty: Difficulty, mode: GameMode) throws {
        for seed in 0..<20 as Range<UInt64> {
            let shots = try Self.shotsToWin(difficulty, mode: mode, seed: seed)
            #expect(shots <= mode.rules.boardSize * mode.rules.boardSize)
        }
    }

    @Test func harderLevelsSinkTheFleetFaster() throws {
        func average(_ difficulty: Difficulty) throws -> Double {
            let games = 60
            var total = 0
            for seed in 0..<UInt64(games) {
                total += try Self.shotsToWin(difficulty, mode: .classic, seed: 1_000 + seed)
            }
            return Double(total) / Double(games)
        }
        let easy = try average(.easy)
        let medium = try average(.medium)
        let hard = try average(.hard)
        // Random play needs ~95 shots on average; hunt/target ~65; probability density ~50.
        #expect(easy > 85)
        #expect(medium < easy - 15)
        #expect(hard < medium)
        #expect(hard < 60)
    }

    @Test(arguments: [Difficulty.medium, .hard])
    func followsUpOnAHit(difficulty: Difficulty) {
        let ai = ComputerOpponent(difficulty: difficulty)
        let hit = Coordinate("E5")!
        let intel = TargetingIntel(
            rules: .classic,
            shots: [Move(player: .one, target: hit, result: .hit)],
            sunkShips: []
        )
        var generator = SeededRandomNumberGenerator(seed: 3)
        for _ in 0..<25 {
            let target = ai.chooseTarget(with: intel, using: &generator)
            #expect(hit.orthogonalNeighbors.contains(target), "\(target) is not next to \(hit)")
        }
    }

    @Test func mediumExtendsALineOfHits() {
        let ai = ComputerOpponent(difficulty: .medium)
        let intel = TargetingIntel(
            rules: .classic,
            shots: [
                Move(player: .one, target: Coordinate("E5")!, result: .hit),
                Move(player: .one, target: Coordinate("E6")!, result: .hit),
            ],
            sunkShips: []
        )
        var generator = SeededRandomNumberGenerator(seed: 11)
        for _ in 0..<25 {
            let target = ai.chooseTarget(with: intel, using: &generator)
            #expect(["E4", "E7"].contains(target.notation))
        }
    }

    @Test func ignoresHitsOnShipsAlreadySunk() {
        let destroyer = ShipPlacement(kind: .destroyer, origin: Coordinate("A1")!, orientation: .horizontal)
        let intel = TargetingIntel(
            rules: .classic,
            shots: [
                Move(player: .one, target: Coordinate("A1")!, result: .hit),
                Move(player: .one, target: Coordinate("A2")!, result: .sunk(.destroyer)),
            ],
            sunkShips: [destroyer]
        )
        #expect(intel.openHits.isEmpty)
        #expect(!intel.remainingShips.contains(.destroyer))
        #expect(intel.remainingShips.count == 4)
    }
}

@Suite("Games against the computer")
struct ComputerMatchTests {
    @Test func computerRepliesOnlyOnItsTurn() throws {
        var generator = SeededRandomNumberGenerator(seed: 9)
        var match = try ComputerMatch(
            mode: .classic,
            difficulty: .hard,
            playerFleet: Rules.classic.randomFleet(using: &generator),
            now: Date(timeIntervalSince1970: 0),
            using: &generator
        )
        #expect(match.isHumansTurn)
        #expect(match.playComputerTurn(using: &generator) == nil)

        try match.fire(at: Coordinate("E5")!, now: Date(timeIntervalSince1970: 60))
        #expect(match.isComputersTurn)
        #expect(match.updatedAt == Date(timeIntervalSince1970: 60))
        let computerMove = match.playComputerTurn(using: &generator)
        let reply = try #require(computerMove)
        #expect(reply.player == ComputerMatch.computer)
        #expect(match.isHumansTurn)
        #expect(match.perspective.enemyShots == [reply])
    }

    @Test func playsToCompletionAndPersists() throws {
        var generator = SeededRandomNumberGenerator(seed: 21)
        var match = try ComputerMatch(
            mode: .quick,
            difficulty: .easy,
            playerFleet: Rules.quick.randomFleet(using: &generator),
            using: &generator
        )
        let human = ComputerOpponent(difficulty: .hard)
        while !match.isOver {
            try match.fire(at: human.chooseTarget(with: match.battle.intel(for: ComputerMatch.human), using: &generator))
            match.playComputerTurn(using: &generator)
        }
        #expect(match.perspective.didWin != nil)
        #expect(match.perspective.knownEnemyShips.count == 5, "the computer's fleet is revealed at the end")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ComputerMatch.self, from: encoder.encode(match))
        #expect(restored.battle == match.battle)
        #expect(restored.id == match.id)
    }

    @Test func resigningEndsTheMatch() throws {
        var match = try ComputerMatch(mode: .classic, difficulty: .medium, playerFleet: Rules.classic.randomFleet())
        try match.resign()
        #expect(match.perspective.didWin == false)
        #expect(match.battle.outcome?.reason == .resignation)
    }
}
