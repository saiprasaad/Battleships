import Foundation

/// A game against the computer, played entirely on the device.
///
/// The human always sits in seat ``Player/one`` and moves first.
public struct ComputerMatch: Identifiable, Hashable, Sendable, Codable {
    public static let human: Player = .one
    public static let computer: Player = .two

    public let id: UUID
    public let difficulty: Difficulty
    public private(set) var battle: Battle
    public let createdAt: Date
    public private(set) var updatedAt: Date

    public init<G: RandomNumberGenerator>(
        id: UUID = UUID(),
        mode: GameMode,
        difficulty: Difficulty,
        playerFleet: [ShipPlacement],
        now: Date = Date(),
        using generator: inout G
    ) throws {
        let computerFleet = ComputerOpponent(difficulty: difficulty).makeFleet(for: mode.rules, using: &generator)
        self.id = id
        self.difficulty = difficulty
        self.battle = try Battle(mode: mode, fleetOne: playerFleet, fleetTwo: computerFleet, firstPlayer: Self.human)
        self.createdAt = now
        self.updatedAt = now
    }

    public init(
        id: UUID = UUID(),
        mode: GameMode,
        difficulty: Difficulty,
        playerFleet: [ShipPlacement],
        now: Date = Date()
    ) throws {
        var generator = SystemRandomNumberGenerator()
        try self.init(id: id, mode: mode, difficulty: difficulty, playerFleet: playerFleet, now: now, using: &generator)
    }

    public var mode: GameMode { battle.mode }
    public var opponent: ComputerOpponent { ComputerOpponent(difficulty: difficulty) }
    public var isOver: Bool { battle.isOver }
    public var isHumansTurn: Bool { battle.turn == Self.human }
    public var isComputersTurn: Bool { battle.turn == Self.computer }

    public var perspective: BattlePerspective {
        battle.perspective(for: Self.human)
    }

    /// The human fires at `target`.
    @discardableResult
    public mutating func fire(at target: Coordinate, now: Date = Date()) throws -> Move {
        let move = try battle.fire(Self.human, at: target)
        updatedAt = now
        return move
    }

    /// Lets the computer take its shot if it is the computer's turn; otherwise does nothing.
    @discardableResult
    public mutating func playComputerTurn<G: RandomNumberGenerator>(now: Date = Date(), using generator: inout G) -> Move? {
        guard isComputersTurn else { return nil }
        let target = opponent.chooseTarget(with: battle.intel(for: Self.computer), using: &generator)
        // The opponent only ever picks untargeted, on-board cells on its own turn, so this cannot fail.
        guard let move = try? battle.fire(Self.computer, at: target) else { return nil }
        updatedAt = now
        return move
    }

    @discardableResult
    public mutating func playComputerTurn(now: Date = Date()) -> Move? {
        var generator = SystemRandomNumberGenerator()
        return playComputerTurn(now: now, using: &generator)
    }

    public mutating func resign(now: Date = Date()) throws {
        try battle.resign(Self.human)
        updatedAt = now
    }
}
