import BattleshipAPI
import BattleshipCore
import Vapor

/// Turns stored games into the redacted views each player is allowed to see.
struct GamePresenter: Sendable {
    let turnTimeLimit: TimeInterval

    func summary(of game: GameRecord, battle: Battle?, for seat: Player) throws -> GameSummary {
        let fleetSize = game.mode.rules.fleet.count
        return GameSummary(
            id: try game.requireID(),
            mode: game.mode,
            status: game.status,
            you: seat,
            opponent: try game.user(at: seat.opponent)?.summary(),
            turn: game.status == .active ? game.turn.flatMap(Player.init(rawValue:)) : nil,
            outcome: game.outcome,
            yourShipsRemaining: battle?.remainingShips(of: seat) ?? fleetSize,
            opponentShipsRemaining: battle?.remainingShips(of: seat.opponent) ?? fleetSize,
            createdAt: game.createdAt ?? Date(),
            updatedAt: game.lastActivity,
            turnDeadline: game.status == .active ? game.lastActivity.addingTimeInterval(turnTimeLimit) : nil
        )
    }

    func summary(of game: GameRecord, for seat: Player) throws -> GameSummary {
        try summary(of: game, battle: game.battle(), for: seat)
    }

    func detail(of game: GameRecord, for seat: Player) throws -> GameDetail {
        let battle = try game.battle()
        let knownOpponentShips: [ShipPlacement] = if let battle {
            // Sunk ships are public knowledge; everything is revealed once the game ends.
            battle.isOver ? battle.fleet(of: seat.opponent) : battle.sunkShips(of: seat.opponent)
        } else {
            []
        }
        return GameDetail(
            summary: try summary(of: game, battle: battle, for: seat),
            yourFleet: seat == .one ? game.fleetOne : (game.fleetTwo ?? []),
            knownOpponentShips: knownOpponentShips,
            moves: game.moves
        )
    }
}

/// Elo ratings: beating a stronger player earns more than beating a weaker one.
enum Elo {
    static let kFactor = 32.0

    static func expectedScore(of rating: Int, against opponent: Int) -> Double {
        1 / (1 + pow(10, Double(opponent - rating) / 400))
    }

    /// New ratings after `winner` beats `loser`. Points are zero-sum, and every win is worth at least one.
    static func ratings(winner: Int, loser: Int) -> (winner: Int, loser: Int) {
        let change = max(1, Int((kFactor * (1 - expectedScore(of: winner, against: loser))).rounded()))
        return (winner + change, loser - change)
    }
}
