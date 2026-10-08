/// The rule sets players can choose between.
public enum GameMode: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    /// 10×10 board with the traditional five-ship fleet.
    case classic
    /// 5×5 board with five single-cell boats: the original Battleships rules.
    case quick

    public var id: String { rawValue }

    public var rules: Rules {
        switch self {
        case .classic: .classic
        case .quick: .quick
        }
    }

    public var displayName: String {
        switch self {
        case .classic: "Classic"
        case .quick: "Quick"
        }
    }

    public var tagline: String {
        switch self {
        case .classic: "10×10 board · Carrier, Battleship, Cruiser, Submarine, Destroyer"
        case .quick: "5×5 board · five single-cell boats · the original rules"
        }
    }
}

/// Why a proposed fleet is not legal.
public enum FleetError: Error, Hashable, Sendable {
    case wrongShips(expected: [ShipKind], received: [ShipKind])
    case outOfBounds(ShipPlacement)
    case overlap(Coordinate)
}

extension FleetError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .wrongShips(expected, received):
            "Fleet must be exactly \(expected.map(\.displayName).joined(separator: ", ")); received \(received.map(\.displayName).joined(separator: ", "))."
        case let .outOfBounds(ship):
            "\(ship.kind.displayName) at \(ship.origin) runs off the board."
        case let .overlap(cell):
            "Ships overlap at \(cell)."
        }
    }
}

public struct Rules: Hashable, Sendable {
    public let boardSize: Int
    /// The ships each player must place, longest first.
    public let fleet: [ShipKind]

    public init(boardSize: Int, fleet: [ShipKind]) {
        precondition((1...26).contains(boardSize), "Board must have between 1 and 26 rows")
        self.boardSize = boardSize
        self.fleet = fleet.sorted(by: Rules.placementOrder)
    }

    public static let classic = Rules(
        boardSize: 10,
        fleet: [.carrier, .battleship, .cruiser, .submarine, .destroyer]
    )

    public static let quick = Rules(
        boardSize: 5,
        fleet: Array(repeating: .patrolBoat, count: 5)
    )

    public var allCoordinates: [Coordinate] {
        (0..<boardSize).flatMap { row in
            (0..<boardSize).map { Coordinate(row: row, column: $0) }
        }
    }

    public func contains(_ coordinate: Coordinate) -> Bool {
        (0..<boardSize).contains(coordinate.row) && (0..<boardSize).contains(coordinate.column)
    }

    public func fits(_ ship: ShipPlacement) -> Bool {
        contains(ship.origin) && contains(ship.end)
    }

    /// Throws a ``FleetError`` unless `placements` is exactly this rule set's fleet,
    /// fully on the board, with no two ships sharing a cell. Ships may touch.
    public func validate(_ placements: [ShipPlacement]) throws {
        let received = placements.map(\.kind).sorted(by: Rules.placementOrder)
        guard received == fleet else {
            throw FleetError.wrongShips(expected: fleet, received: received)
        }
        var occupied = Set<Coordinate>()
        for ship in placements {
            guard fits(ship) else { throw FleetError.outOfBounds(ship) }
            for cell in ship.cells where !occupied.insert(cell).inserted {
                throw FleetError.overlap(cell)
            }
        }
    }

    public func isValid(_ placements: [ShipPlacement]) -> Bool {
        (try? validate(placements)) != nil
    }

    /// Every on-board position for a ship of `kind`. Single-cell ships only get one orientation.
    public func possiblePlacements(of kind: ShipKind) -> [ShipPlacement] {
        let orientations: [Orientation] = kind.length == 1 ? [.horizontal] : Orientation.allCases
        return orientations.flatMap { orientation in
            allCoordinates
                .map { ShipPlacement(kind: kind, origin: $0, orientation: orientation) }
                .filter(fits)
        }
    }

    /// A uniformly shuffled legal fleet.
    public func randomFleet<G: RandomNumberGenerator>(using generator: inout G) -> [ShipPlacement] {
        // Longest ships first rarely needs a retry; backtracking guarantees termination
        // for any rule set that admits a legal fleet at all.
        var placed: [ShipPlacement] = []
        if placeRemaining(fleet[...], into: &placed, using: &generator) {
            return placed
        }
        preconditionFailure("No legal fleet exists for \(self)")
    }

    public func randomFleet() -> [ShipPlacement] {
        var generator = SystemRandomNumberGenerator()
        return randomFleet(using: &generator)
    }

    private func placeRemaining<G: RandomNumberGenerator>(
        _ remaining: ArraySlice<ShipKind>,
        into placed: inout [ShipPlacement],
        using generator: inout G
    ) -> Bool {
        guard let kind = remaining.first else { return true }
        let candidates = possiblePlacements(of: kind)
            .filter { candidate in !placed.contains(where: candidate.overlaps) }
            .shuffled(using: &generator)
        for candidate in candidates {
            placed.append(candidate)
            if placeRemaining(remaining.dropFirst(), into: &placed, using: &generator) {
                return true
            }
            placed.removeLast()
        }
        return false
    }

    private static func placementOrder(_ lhs: ShipKind, _ rhs: ShipKind) -> Bool {
        if lhs.length != rhs.length { return lhs.length > rhs.length }
        return lhs.rawValue < rhs.rawValue
    }
}
