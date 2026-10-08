/// The classes of ship that can make up a fleet.
public enum ShipKind: String, Codable, Sendable, CaseIterable, Hashable {
    case carrier
    case battleship
    case cruiser
    case submarine
    case destroyer
    /// A single-cell boat, used by the quick 5×5 mode (the original Battleships rules).
    case patrolBoat

    public var length: Int {
        switch self {
        case .carrier: 5
        case .battleship: 4
        case .cruiser, .submarine: 3
        case .destroyer: 2
        case .patrolBoat: 1
        }
    }

    public var displayName: String {
        switch self {
        case .carrier: "Carrier"
        case .battleship: "Battleship"
        case .cruiser: "Cruiser"
        case .submarine: "Submarine"
        case .destroyer: "Destroyer"
        case .patrolBoat: "Patrol Boat"
        }
    }
}

public enum Orientation: String, Codable, Sendable, CaseIterable, Hashable {
    case horizontal
    case vertical

    public var toggled: Orientation {
        self == .horizontal ? .vertical : .horizontal
    }
}

/// A ship positioned on a board.
///
/// `origin` is the bow: the leftmost cell of a horizontal ship or the topmost cell of a vertical one.
/// Because ships never overlap, a placement is uniquely identified within a fleet by its origin.
public struct ShipPlacement: Hashable, Sendable, Codable {
    public let kind: ShipKind
    public let origin: Coordinate
    public let orientation: Orientation

    public init(kind: ShipKind, origin: Coordinate, orientation: Orientation) {
        self.kind = kind
        self.origin = origin
        self.orientation = orientation
    }

    public var length: Int { kind.length }

    /// Every cell the ship covers, bow first.
    public var cells: [Coordinate] {
        (0..<length).map(cell(at:))
    }

    /// The stern (last) cell.
    public var end: Coordinate { cell(at: length - 1) }

    public func contains(_ coordinate: Coordinate) -> Bool {
        switch orientation {
        case .horizontal:
            coordinate.row == origin.row
                && coordinate.column >= origin.column
                && coordinate.column < origin.column + length
        case .vertical:
            coordinate.column == origin.column
                && coordinate.row >= origin.row
                && coordinate.row < origin.row + length
        }
    }

    /// Index of `coordinate` along the ship (0 is the bow), or `nil` if the ship doesn't cover it.
    public func segmentIndex(of coordinate: Coordinate) -> Int? {
        guard contains(coordinate) else { return nil }
        return orientation == .horizontal
            ? coordinate.column - origin.column
            : coordinate.row - origin.row
    }

    public func moved(to origin: Coordinate) -> ShipPlacement {
        ShipPlacement(kind: kind, origin: origin, orientation: orientation)
    }

    public func rotated() -> ShipPlacement {
        ShipPlacement(kind: kind, origin: origin, orientation: orientation.toggled)
    }

    public func overlaps(_ other: ShipPlacement) -> Bool {
        cells.contains(where: other.contains)
    }

    private func cell(at index: Int) -> Coordinate {
        orientation == .horizontal
            ? origin.offsetBy(columns: index)
            : origin.offsetBy(rows: index)
    }
}
