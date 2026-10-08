import BattleshipCore
import Foundation
import Observation

/// The fleet being arranged before a battle. It always holds a legal fleet: it starts shuffled,
/// and moves or rotations that would break the rules are refused.
@MainActor
@Observable
final class FleetPlacementModel {
    let rules: Rules
    private(set) var ships: [ShipPlacement]
    var selectedIndex: Int?

    init(rules: Rules, ships: [ShipPlacement]? = nil) {
        self.rules = rules
        self.ships = ships.flatMap { rules.isValid($0) ? $0 : nil } ?? rules.randomFleet()
    }

    var isValid: Bool { rules.isValid(ships) }

    func shuffle() {
        ships = rules.randomFleet()
        selectedIndex = nil
    }

    func shipIndex(at coordinate: Coordinate) -> Int? {
        ships.firstIndex { $0.contains(coordinate) }
    }

    func canPlace(_ candidate: ShipPlacement, replacing index: Int) -> Bool {
        rules.fits(candidate) && !ships.indices.contains { other in
            other != index && ships[other].overlaps(candidate)
        }
    }

    /// Moves a ship so its bow is at `origin`. Returns `false` (and changes nothing) if it doesn't fit.
    @discardableResult
    func move(_ index: Int, to origin: Coordinate) -> Bool {
        guard ships.indices.contains(index) else { return false }
        let candidate = ships[index].moved(to: origin)
        guard canPlace(candidate, replacing: index) else { return false }
        ships[index] = candidate
        return true
    }

    /// Rotates a ship about its bow, sliding it back along its new axis if it would hang off the
    /// board or hit another ship. Returns `false` if there's no room at all.
    @discardableResult
    func rotate(_ index: Int) -> Bool {
        guard ships.indices.contains(index), ships[index].length > 1 else { return false }
        let rotated = ships[index].rotated()
        for shift in 0..<rotated.length {
            let origin = rotated.orientation == .horizontal
                ? rotated.origin.offsetBy(columns: -shift)
                : rotated.origin.offsetBy(rows: -shift)
            let candidate = rotated.moved(to: origin)
            if canPlace(candidate, replacing: index) {
                ships[index] = candidate
                return true
            }
        }
        return false
    }

    /// Nudges a ship one cell in a direction, for keyboard and VoiceOver users.
    @discardableResult
    func nudge(_ index: Int, rows: Int = 0, columns: Int = 0) -> Bool {
        guard ships.indices.contains(index) else { return false }
        return move(index, to: ships[index].origin.offsetBy(rows: rows, columns: columns))
    }
}
