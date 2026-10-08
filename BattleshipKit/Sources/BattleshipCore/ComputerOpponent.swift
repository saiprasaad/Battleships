/// How hard the computer plays.
public enum Difficulty: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    /// Fires at random.
    case easy
    /// Hunts on a checkerboard and, after a hit, works along the ship until it sinks.
    case medium
    /// Fires where the remaining ships are most likely to be, based on every placement still possible.
    case hard

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .easy: "Cadet"
        case .medium: "Captain"
        case .hard: "Admiral"
        }
    }

    public var tagline: String {
        switch self {
        case .easy: "Fires blind. Good for learning the ropes."
        case .medium: "Hunts methodically and finishes what it hits."
        case .hard: "Calculates the odds on every shot."
        }
    }
}

/// Everything a shooter legitimately knows about the board they are attacking.
public struct TargetingIntel: Sendable {
    public let rules: Rules
    public let misses: Set<Coordinate>
    /// Hits on ships that are still afloat.
    public let openHits: Set<Coordinate>
    /// Enemy ships that have been sunk (their positions are revealed when they go down).
    public let sunkShips: [ShipPlacement]
    /// Ships not yet sunk.
    public let remainingShips: [ShipKind]
    /// Every cell already fired at.
    public let targeted: Set<Coordinate>

    public init(rules: Rules, shots: [Move], sunkShips: [ShipPlacement]) {
        self.rules = rules
        self.sunkShips = sunkShips
        let sunkCells = Set(sunkShips.flatMap(\.cells))
        misses = Set(shots.filter { !$0.result.isHit }.map(\.target))
        openHits = Set(shots.filter { $0.result.isHit && !sunkCells.contains($0.target) }.map(\.target))

        var remaining = rules.fleet
        for ship in sunkShips {
            if let index = remaining.firstIndex(of: ship.kind) {
                remaining.remove(at: index)
            }
        }
        remainingShips = remaining
        targeted = Set(shots.map(\.target))
    }

    public var untargeted: [Coordinate] {
        rules.allCoordinates.filter { !targeted.contains($0) }
    }
}

extension Battle {
    /// What `shooter` knows about their opponent's board.
    public func intel(for shooter: Player) -> TargetingIntel {
        TargetingIntel(rules: rules, shots: shots(by: shooter), sunkShips: sunkShips(of: shooter.opponent))
    }
}

/// The computer player: places a fleet and picks targets at a chosen ``Difficulty``.
public struct ComputerOpponent: Sendable, Hashable {
    public let difficulty: Difficulty

    public init(difficulty: Difficulty) {
        self.difficulty = difficulty
    }

    public func makeFleet<G: RandomNumberGenerator>(for rules: Rules, using generator: inout G) -> [ShipPlacement] {
        rules.randomFleet(using: &generator)
    }

    /// Picks the next cell to fire at. Always returns a cell that has not been targeted yet.
    public func chooseTarget<G: RandomNumberGenerator>(with intel: TargetingIntel, using generator: inout G) -> Coordinate {
        let options = intel.untargeted
        precondition(!options.isEmpty, "Every cell has already been targeted")

        let choice: Coordinate? = switch difficulty {
        case .easy: options.randomElement(using: &generator)
        case .medium: Self.huntAndTarget(intel, options: options, using: &generator)
        case .hard: Self.probabilityDensity(intel, options: options, using: &generator)
        }
        return choice ?? options.randomElement(using: &generator)!
    }

    public func chooseTarget(with intel: TargetingIntel) -> Coordinate {
        var generator = SystemRandomNumberGenerator()
        return chooseTarget(with: intel, using: &generator)
    }

    // MARK: Medium

    private static func huntAndTarget<G: RandomNumberGenerator>(
        _ intel: TargetingIntel,
        options: [Coordinate],
        using generator: inout G
    ) -> Coordinate? {
        let open = Set(options)

        if !intel.openHits.isEmpty {
            // Sets iterate in a different order on every launch; sort so a seed always replays the same game.
            let hits = intel.openHits.sorted()
            // Two or more hits in a line: keep going along that line.
            var lineEnds: [Coordinate] = []
            for hit in hits {
                for (dr, dc) in [(0, 1), (1, 0)] {
                    let next = hit.offsetBy(rows: dr, columns: dc)
                    guard intel.openHits.contains(next) else { continue }
                    var before = hit
                    while intel.openHits.contains(before.offsetBy(rows: -dr, columns: -dc)) {
                        before = before.offsetBy(rows: -dr, columns: -dc)
                    }
                    var after = next
                    while intel.openHits.contains(after.offsetBy(rows: dr, columns: dc)) {
                        after = after.offsetBy(rows: dr, columns: dc)
                    }
                    lineEnds.append(before.offsetBy(rows: -dr, columns: -dc))
                    lineEnds.append(after.offsetBy(rows: dr, columns: dc))
                }
            }
            if let target = lineEnds.filter(open.contains).randomElement(using: &generator) {
                return target
            }
            // A lone hit (or a blocked line): try its neighbours.
            let neighbors = hits.flatMap(\.orthogonalNeighbors).filter(open.contains)
            if let target = neighbors.randomElement(using: &generator) {
                return target
            }
        }

        // Hunting: every ship of length ≥ n must cover a cell on an n-spaced diagonal lattice.
        let shortest = intel.remainingShips.map(\.length).min() ?? 1
        if shortest > 1 {
            let lattice = options.filter { ($0.row + $0.column) % shortest == 0 }
            if let target = lattice.randomElement(using: &generator) {
                return target
            }
        }
        return options.randomElement(using: &generator)
    }

    // MARK: Hard

    private static func probabilityDensity<G: RandomNumberGenerator>(
        _ intel: TargetingIntel,
        options: [Coordinate],
        using generator: inout G
    ) -> Coordinate? {
        let blocked = intel.misses.union(intel.sunkShips.flatMap(\.cells))
        let open = Set(options)
        var scores: [Coordinate: Int] = [:]

        // Count every way each surviving ship could still be lying on the board. Placements that
        // explain existing hits are weighted far more heavily, which turns "hunt" into "target".
        for kind in Set(intel.remainingShips) {
            let copies = intel.remainingShips.filter { $0 == kind }.count
            for placement in intel.rules.possiblePlacements(of: kind) {
                let cells = placement.cells
                guard !cells.contains(where: blocked.contains) else { continue }
                let coveredHits = cells.filter(intel.openHits.contains).count
                let weight = (coveredHits == 0 ? 1 : 40 * coveredHits * coveredHits) * copies
                for cell in cells where open.contains(cell) {
                    scores[cell, default: 0] += weight
                }
            }
        }

        guard let best = scores.values.max(), best > 0 else { return nil }
        let candidates = options.filter { scores[$0] == best }
        return candidates.randomElement(using: &generator)
    }
}
