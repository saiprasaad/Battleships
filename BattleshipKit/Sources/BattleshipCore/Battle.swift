/// A seat at the table. Player one always creates the game.
public enum Player: Int, Codable, Sendable, CaseIterable, Hashable {
    case one = 1
    case two = 2

    public var opponent: Player {
        self == .one ? .two : .one
    }
}

public enum ShotResult: Hashable, Sendable {
    case miss
    case hit
    /// The shot finished off a ship, revealing its class.
    case sunk(ShipKind)

    public var isHit: Bool {
        if case .miss = self { return false }
        return true
    }
}

/// A shot fired by `player` at `target` on their opponent's board.
public struct Move: Hashable, Sendable {
    public let player: Player
    public let target: Coordinate
    public let result: ShotResult

    public init(player: Player, target: Coordinate, result: ShotResult) {
        self.player = player
        self.target = target
        self.result = result
    }
}

extension Move: Codable {
    private enum CodingKeys: String, CodingKey {
        case player, target, result, ship
    }

    private enum ResultTag: String, Codable {
        case miss, hit, sunk
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        player = try container.decode(Player.self, forKey: .player)
        target = try container.decode(Coordinate.self, forKey: .target)
        switch try container.decode(ResultTag.self, forKey: .result) {
        case .miss: result = .miss
        case .hit: result = .hit
        case .sunk: result = .sunk(try container.decode(ShipKind.self, forKey: .ship))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(player, forKey: .player)
        try container.encode(target, forKey: .target)
        switch result {
        case .miss:
            try container.encode(ResultTag.miss, forKey: .result)
        case .hit:
            try container.encode(ResultTag.hit, forKey: .result)
        case let .sunk(kind):
            try container.encode(ResultTag.sunk, forKey: .result)
            try container.encode(kind, forKey: .ship)
        }
    }
}

public struct Outcome: Hashable, Sendable, Codable {
    public enum Reason: String, Hashable, Sendable, Codable {
        /// Every ship of the loser was sunk.
        case fleetDestroyed
        /// The loser gave up.
        case resignation
        /// The loser took too long to move and their opponent claimed the win.
        case timeout
    }

    public let winner: Player
    public let reason: Reason

    public init(winner: Player, reason: Reason) {
        self.winner = winner
        self.reason = reason
    }

    public var loser: Player { winner.opponent }
}

public enum BattleError: Error, Hashable, Sendable {
    case gameOver
    case notYourTurn
    case outOfBounds(Coordinate)
    case alreadyTargeted(Coordinate)
    /// A stored game could not be replayed (its recorded moves disagree with the fleets).
    case corrupted(String)
}

extension BattleError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .gameOver: "The game is already over."
        case .notYourTurn: "It's not your turn."
        case let .outOfBounds(target): "\(target) is not on the board."
        case let .alreadyTargeted(target): "You already fired at \(target)."
        case let .corrupted(reason): "Game data is inconsistent: \(reason)"
        }
    }
}

/// The complete, authoritative state of a game in progress: both fleets, every shot, and the result.
///
/// Players alternate single shots (a hit does not grant an extra turn). A ship sinks once all of its
/// cells are hit, and the first player to sink the entire opposing fleet wins.
public struct Battle: Hashable, Sendable {
    public let mode: GameMode
    public let firstPlayer: Player
    private let fleetOne: [ShipPlacement]
    private let fleetTwo: [ShipPlacement]
    public private(set) var moves: [Move] = []
    public private(set) var outcome: Outcome?

    public init(
        mode: GameMode,
        fleetOne: [ShipPlacement],
        fleetTwo: [ShipPlacement],
        firstPlayer: Player = .one
    ) throws {
        try mode.rules.validate(fleetOne)
        try mode.rules.validate(fleetTwo)
        self.mode = mode
        self.fleetOne = fleetOne
        self.fleetTwo = fleetTwo
        self.firstPlayer = firstPlayer
    }

    /// Rebuilds a stored game by replaying its moves, verifying every recorded result.
    ///
    /// - Parameter forfeit: how the game ended, if it ended without a fleet being sunk
    ///   (a resignation or a timeout). Ignored for `.fleetDestroyed`, which the moves determine.
    public init(
        mode: GameMode,
        fleetOne: [ShipPlacement],
        fleetTwo: [ShipPlacement],
        firstPlayer: Player = .one,
        replaying recordedMoves: [Move],
        forfeit: Outcome? = nil
    ) throws {
        try self.init(mode: mode, fleetOne: fleetOne, fleetTwo: fleetTwo, firstPlayer: firstPlayer)
        for recorded in recordedMoves {
            let replayed = try fire(recorded.player, at: recorded.target)
            guard replayed == recorded else {
                throw BattleError.corrupted("\(recorded.target) recorded as \(recorded.result) but is \(replayed.result)")
            }
        }
        if let forfeit, forfeit.reason != .fleetDestroyed {
            try self.forfeit(forfeit.loser, reason: forfeit.reason)
        }
    }

    public var rules: Rules { mode.rules }

    /// Whose move it is, or `nil` once the game is over.
    public var turn: Player? {
        guard outcome == nil else { return nil }
        return moves.last.map { $0.player.opponent } ?? firstPlayer
    }

    public var isOver: Bool { outcome != nil }

    public func fleet(of player: Player) -> [ShipPlacement] {
        player == .one ? fleetOne : fleetTwo
    }

    /// Shots fired by `player`, in order.
    public func shots(by player: Player) -> [Move] {
        moves.filter { $0.player == player }
    }

    public func hasTargeted(_ target: Coordinate, by player: Player) -> Bool {
        moves.contains { $0.player == player && $0.target == target }
    }

    /// `player`'s own ships that have been sunk.
    public func sunkShips(of player: Player) -> [ShipPlacement] {
        let incoming = Set(shots(by: player.opponent).map(\.target))
        return fleet(of: player).filter { ship in ship.cells.allSatisfy(incoming.contains) }
    }

    public func remainingShips(of player: Player) -> Int {
        fleet(of: player).count - sunkShips(of: player).count
    }

    /// Fires a shot for `player`. Throws a ``BattleError`` if the shot is not legal right now.
    @discardableResult
    public mutating func fire(_ player: Player, at target: Coordinate) throws -> Move {
        guard outcome == nil else { throw BattleError.gameOver }
        guard turn == player else { throw BattleError.notYourTurn }
        guard rules.contains(target) else { throw BattleError.outOfBounds(target) }
        guard !hasTargeted(target, by: player) else { throw BattleError.alreadyTargeted(target) }

        let defendingFleet = fleet(of: player.opponent)
        let result: ShotResult
        if let ship = defendingFleet.first(where: { $0.contains(target) }) {
            var hitCells = Set(shots(by: player).map(\.target))
            hitCells.insert(target)
            result = ship.cells.allSatisfy(hitCells.contains) ? .sunk(ship.kind) : .hit
        } else {
            result = .miss
        }

        let move = Move(player: player, target: target, result: result)
        moves.append(move)

        if case .sunk = result, remainingShips(of: player.opponent) == 0 {
            outcome = Outcome(winner: player, reason: .fleetDestroyed)
        }
        return move
    }

    /// Concedes the game; the other player wins.
    public mutating func resign(_ player: Player) throws {
        try forfeit(player, reason: .resignation)
    }

    /// Ends the game in the opponent's favour without sinking `player`'s fleet.
    public mutating func forfeit(_ player: Player, reason: Outcome.Reason) throws {
        guard outcome == nil else { throw BattleError.gameOver }
        precondition(reason != .fleetDestroyed, "A destroyed fleet is decided by the moves, not declared")
        outcome = Outcome(winner: player.opponent, reason: reason)
    }

    /// The game as `player` is allowed to see it: their own fleet in full, but only the opposing ships
    /// they have sunk, unless `revealOpponent` is set (by default, once the game is over).
    public func perspective(for player: Player, revealOpponent: Bool? = nil) -> BattlePerspective {
        let reveal = revealOpponent ?? isOver
        return BattlePerspective(
            mode: mode,
            me: player,
            myFleet: fleet(of: player),
            knownEnemyShips: reveal ? fleet(of: player.opponent) : sunkShips(of: player.opponent),
            moves: moves,
            turn: turn,
            outcome: outcome
        )
    }
}

extension Battle: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode, firstPlayer, fleetOne, fleetTwo, moves, outcome
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decodeIfPresent(Outcome.self, forKey: .outcome)
        do {
            try self.init(
                mode: container.decode(GameMode.self, forKey: .mode),
                fleetOne: container.decode([ShipPlacement].self, forKey: .fleetOne),
                fleetTwo: container.decode([ShipPlacement].self, forKey: .fleetTwo),
                firstPlayer: container.decode(Player.self, forKey: .firstPlayer),
                replaying: container.decode([Move].self, forKey: .moves),
                forfeit: outcome
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Stored battle is not a legal game: \(error)",
                underlyingError: error
            ))
        }
        guard self.outcome == outcome else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Stored outcome does not match the replayed moves."
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(firstPlayer, forKey: .firstPlayer)
        try container.encode(fleetOne, forKey: .fleetOne)
        try container.encode(fleetTwo, forKey: .fleetTwo)
        try container.encode(moves, forKey: .moves)
        try container.encodeIfPresent(outcome, forKey: .outcome)
    }
}
