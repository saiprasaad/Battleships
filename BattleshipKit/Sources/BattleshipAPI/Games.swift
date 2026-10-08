import BattleshipCore
import Foundation

public enum GameStatus: String, Codable, Sendable, CaseIterable, Hashable {
    /// Waiting in the queue for a random opponent.
    case matchmaking
    /// A challenge sent to a specific player, waiting for them to accept.
    case invited
    case active
    case finished
}

/// A game as it appears in the lobby, from the requesting player's point of view.
public struct GameSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var mode: GameMode
    public var status: GameStatus
    /// The requesting player's seat. Player one created the game and moves first.
    public var you: Player
    /// `nil` while matchmaking, or if the opponent has since deleted their account.
    public var opponent: PlayerSummary?
    public var turn: Player?
    public var outcome: Outcome?
    public var yourShipsRemaining: Int
    public var opponentShipsRemaining: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// When the player whose turn it is runs out of time. After this, their opponent can claim the win.
    /// `nil` unless the game is active.
    public var turnDeadline: Date?

    public init(
        id: UUID,
        mode: GameMode,
        status: GameStatus,
        you: Player,
        opponent: PlayerSummary?,
        turn: Player?,
        outcome: Outcome?,
        yourShipsRemaining: Int,
        opponentShipsRemaining: Int,
        createdAt: Date,
        updatedAt: Date,
        turnDeadline: Date? = nil
    ) {
        self.id = id
        self.mode = mode
        self.status = status
        self.you = you
        self.opponent = opponent
        self.turn = turn
        self.outcome = outcome
        self.yourShipsRemaining = yourShipsRemaining
        self.opponentShipsRemaining = opponentShipsRemaining
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turnDeadline = turnDeadline
    }

    public var isYourTurn: Bool { status == .active && turn == you }
    public var isTheirTurn: Bool { status == .active && turn == you.opponent }
    /// Someone challenged you and is waiting for your answer.
    public var isIncomingChallenge: Bool { status == .invited && you == .two }
    /// You challenged someone and are waiting for their answer.
    public var isOutgoingChallenge: Bool { status == .invited && you == .one }

    /// `true` if you won, `false` if you lost, `nil` if the game isn't over.
    public var didWin: Bool? {
        outcome.map { $0.winner == you }
    }

    /// Your opponent has used up their time to move, so you can claim the win.
    public func canClaimVictory(at now: Date = Date()) -> Bool {
        guard isTheirTurn, let turnDeadline else { return false }
        return now >= turnDeadline
    }

    public var opponentName: String {
        opponent?.username ?? (status == .matchmaking ? "Finding opponent…" : "Former player")
    }
}

/// Everything about one game that the requesting player is allowed to see.
///
/// The opponent's ships are only included once they are sunk, or when the game is finished.
public struct GameDetail: Codable, Sendable, Hashable, Identifiable {
    public var summary: GameSummary
    /// Empty until you have placed your fleet (an incoming challenge you haven't accepted yet).
    public var yourFleet: [ShipPlacement]
    public var knownOpponentShips: [ShipPlacement]
    public var moves: [Move]

    public init(summary: GameSummary, yourFleet: [ShipPlacement], knownOpponentShips: [ShipPlacement], moves: [Move]) {
        self.summary = summary
        self.yourFleet = yourFleet
        self.knownOpponentShips = knownOpponentShips
        self.moves = moves
    }

    public var id: UUID { summary.id }

    public var perspective: BattlePerspective {
        BattlePerspective(
            mode: summary.mode,
            me: summary.you,
            myFleet: yourFleet,
            knownEnemyShips: knownOpponentShips,
            moves: moves,
            turn: summary.status == .active ? summary.turn : nil,
            outcome: summary.outcome
        )
    }
}

/// Starts a game. With `opponent` set, challenges that player by username;
/// otherwise joins matchmaking and is paired with the next player looking for the same mode.
public struct CreateGameRequest: Codable, Sendable, Hashable {
    public var mode: GameMode
    public var fleet: [ShipPlacement]
    public var opponent: String?

    public init(mode: GameMode, fleet: [ShipPlacement], opponent: String? = nil) {
        self.mode = mode
        self.fleet = fleet
        self.opponent = opponent
    }
}

public struct AcceptChallengeRequest: Codable, Sendable, Hashable {
    public var fleet: [ShipPlacement]

    public init(fleet: [ShipPlacement]) {
        self.fleet = fleet
    }
}

public struct FireRequest: Codable, Sendable, Hashable {
    public var target: Coordinate

    public init(target: Coordinate) {
        self.target = target
    }
}

public struct FireResponse: Codable, Sendable, Hashable {
    public var move: Move
    public var game: GameDetail

    public init(move: Move, game: GameDetail) {
        self.move = move
        self.game = game
    }
}
