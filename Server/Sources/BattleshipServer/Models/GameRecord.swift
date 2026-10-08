import BattleshipAPI
import BattleshipCore
import Fluent
import Vapor

/// A stored game. The fleets plus the move log are the source of truth; `turn`, `winner` and
/// `status` are kept alongside so games can be listed and matched without replaying them.
final class GameRecord: Model, @unchecked Sendable {
    static let schema = "games"

    @ID(key: .id) var id: UUID?
    @Field(key: "mode") var modeRaw: String
    @Field(key: "status") var statusRaw: String
    /// The player who created the game. `nil` only if they later deleted their account.
    @OptionalParent(key: "player_one_id") var playerOne: User?
    /// The opponent: the challenged player, the matched player, or `nil` while matchmaking.
    @OptionalParent(key: "player_two_id") var playerTwo: User?
    @Field(key: "fleet_one") var fleetOne: [ShipPlacement]
    @OptionalField(key: "fleet_two") var fleetTwo: [ShipPlacement]?
    @Field(key: "moves") var moves: [Move]
    @OptionalField(key: "turn") var turn: Int?
    @OptionalField(key: "winner") var winner: Int?
    @OptionalField(key: "end_reason") var endReason: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(mode: GameMode, status: GameStatus, playerOneID: UUID, playerTwoID: UUID?, fleetOne: [ShipPlacement]) {
        self.modeRaw = mode.rawValue
        self.statusRaw = status.rawValue
        self.$playerOne.id = playerOneID
        self.$playerTwo.id = playerTwoID
        self.fleetOne = fleetOne
        self.fleetTwo = nil
        self.moves = []
    }

    var mode: GameMode {
        get { GameMode(rawValue: modeRaw) ?? .classic }
        set { modeRaw = newValue.rawValue }
    }

    var status: GameStatus {
        get { GameStatus(rawValue: statusRaw) ?? .finished }
        set { statusRaw = newValue.rawValue }
    }

    var outcome: Outcome? {
        guard let winner, let seat = Player(rawValue: winner),
              let reason = endReason.flatMap(Outcome.Reason.init(rawValue:))
        else { return nil }
        return Outcome(winner: seat, reason: reason)
    }

    func seat(of userID: UUID) -> Player? {
        if $playerOne.id == userID { return .one }
        if $playerTwo.id == userID { return .two }
        return nil
    }

    func userID(at seat: Player) -> UUID? {
        seat == .one ? $playerOne.id : $playerTwo.id
    }

    /// The loaded user in `seat`, or `nil` if the seat is empty (or the relation wasn't loaded).
    func user(at seat: Player) -> User? {
        let loaded = seat == .one ? $playerOne.value : $playerTwo.value
        return loaded ?? nil
    }

    /// Replays the stored moves. `nil` until both fleets are in.
    func battle() throws -> Battle? {
        guard let fleetTwo, status == .active || status == .finished else { return nil }
        return try Battle(mode: mode, fleetOne: fleetOne, fleetTwo: fleetTwo, replaying: moves, forfeit: outcome)
    }

    /// When the last move (or the start of the battle) happened.
    var lastActivity: Date {
        updatedAt ?? createdAt ?? Date()
    }

    /// Copies a battle's progress back into the record.
    func apply(_ battle: Battle) {
        moves = battle.moves
        turn = battle.turn?.rawValue
        if let outcome = battle.outcome {
            status = .finished
            winner = outcome.winner.rawValue
            endReason = outcome.reason.rawValue
        }
    }
}
