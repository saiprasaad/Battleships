/// What a mark on a board cell shows.
public enum CellMark: Hashable, Sendable {
    case miss
    case hit
    /// Part of a ship that has gone down.
    case sunk
}

/// Shooting statistics for one side of a battle.
public struct ShotStats: Hashable, Sendable {
    public let shotsFired: Int
    public let hits: Int

    public init(shotsFired: Int, hits: Int) {
        self.shotsFired = shotsFired
        self.hits = hits
    }

    /// Fraction of shots that hit, or `nil` before the first shot.
    public var accuracy: Double? {
        shotsFired == 0 ? nil : Double(hits) / Double(shotsFired)
    }
}

/// One player's view of a battle: everything needed to draw both boards without leaking
/// the positions of enemy ships that are still afloat.
///
/// The app builds this either from a local ``Battle`` (games against the computer) or from
/// the server's redacted game payload (online games), and renders both the same way.
public struct BattlePerspective: Hashable, Sendable {
    public let mode: GameMode
    public let me: Player
    public let myFleet: [ShipPlacement]
    /// Enemy ships whose positions are known: the ones sunk so far, or the whole fleet once revealed.
    public let knownEnemyShips: [ShipPlacement]
    public let moves: [Move]
    public let turn: Player?
    public let outcome: Outcome?

    private let targetMarks: [Coordinate: CellMark]
    private let homeMarks: [Coordinate: CellMark]
    private let sunkEnemyShipCount: Int
    private let sunkFriendlyShips: [ShipPlacement]

    public init(
        mode: GameMode,
        me: Player,
        myFleet: [ShipPlacement],
        knownEnemyShips: [ShipPlacement],
        moves: [Move],
        turn: Player?,
        outcome: Outcome?
    ) {
        self.mode = mode
        self.me = me
        self.myFleet = myFleet
        self.knownEnemyShips = knownEnemyShips
        self.moves = moves
        self.turn = turn
        self.outcome = outcome

        // Enemy waters: my shots. Hits on ships known to be sunk render as wreckage.
        var targetMarks: [Coordinate: CellMark] = [:]
        var sunkEnemyShipCount = 0
        var sunkEnemyCells = Set<Coordinate>()
        for move in moves where move.player == me {
            if case .sunk = move.result {
                sunkEnemyShipCount += 1
                if let ship = knownEnemyShips.first(where: { $0.contains(move.target) }) {
                    sunkEnemyCells.formUnion(ship.cells)
                }
            }
        }
        for move in moves where move.player == me {
            if !move.result.isHit {
                targetMarks[move.target] = .miss
            } else {
                targetMarks[move.target] = sunkEnemyCells.contains(move.target) ? .sunk : .hit
            }
        }

        // Home waters: the opponent's shots against my fleet.
        let incoming = Set(moves.filter { $0.player != me }.map(\.target))
        let sunkFriendlyShips = myFleet.filter { ship in ship.cells.allSatisfy(incoming.contains) }
        let sunkFriendlyCells = Set(sunkFriendlyShips.flatMap(\.cells))
        var homeMarks: [Coordinate: CellMark] = [:]
        for move in moves where move.player != me {
            if !move.result.isHit {
                homeMarks[move.target] = .miss
            } else {
                homeMarks[move.target] = sunkFriendlyCells.contains(move.target) ? .sunk : .hit
            }
        }

        self.targetMarks = targetMarks
        self.homeMarks = homeMarks
        self.sunkEnemyShipCount = sunkEnemyShipCount
        self.sunkFriendlyShips = sunkFriendlyShips
    }

    public var rules: Rules { mode.rules }
    public var isMyTurn: Bool { turn == me }
    public var isFinished: Bool { outcome != nil }

    /// `true` if I won, `false` if I lost, `nil` while the game is still going.
    public var didWin: Bool? {
        outcome.map { $0.winner == me }
    }

    public var myShots: [Move] { moves.filter { $0.player == me } }
    public var enemyShots: [Move] { moves.filter { $0.player != me } }

    /// What my shots have revealed at `coordinate` on the enemy's board.
    public func targetMark(at coordinate: Coordinate) -> CellMark? {
        targetMarks[coordinate]
    }

    /// What the enemy's shots have done at `coordinate` on my board.
    public func homeMark(at coordinate: Coordinate) -> CellMark? {
        homeMarks[coordinate]
    }

    public func canTarget(_ coordinate: Coordinate) -> Bool {
        isMyTurn && rules.contains(coordinate) && targetMarks[coordinate] == nil
    }

    public func myShip(at coordinate: Coordinate) -> ShipPlacement? {
        myFleet.first { $0.contains(coordinate) }
    }

    public func knownEnemyShip(at coordinate: Coordinate) -> ShipPlacement? {
        knownEnemyShips.first { $0.contains(coordinate) }
    }

    public func isSunk(_ ship: ShipPlacement) -> Bool {
        if myFleet.contains(ship) {
            return sunkFriendlyShips.contains(ship)
        }
        return ship.cells.allSatisfy { targetMarks[$0] == .sunk }
    }

    public var myShipsRemaining: Int { myFleet.count - sunkFriendlyShips.count }
    public var enemyShipsRemaining: Int { rules.fleet.count - sunkEnemyShipCount }

    public var myStats: ShotStats {
        let shots = myShots
        return ShotStats(shotsFired: shots.count, hits: shots.filter(\.result.isHit).count)
    }

    public var enemyStats: ShotStats {
        let shots = enemyShots
        return ShotStats(shotsFired: shots.count, hits: shots.filter(\.result.isHit).count)
    }
}
