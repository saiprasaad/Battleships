import BattleshipCore
import Foundation
import Testing

@Suite("Coordinates")
struct CoordinateTests {
    @Test(arguments: [
        ("A1", 0, 0),
        ("b7", 1, 6),
        ("J10", 9, 9),
        ("Z26", 25, 25),
    ])
    func parsesNotation(notation: String, row: Int, column: Int) {
        #expect(Coordinate(notation) == Coordinate(row: row, column: column))
    }

    @Test(arguments: ["", "A", "1A", "AA1", "A0", "A01", "A-1", "A+1", "A1 ", "Ä1", "A100"])
    func rejectsMalformedNotation(notation: String) {
        #expect(Coordinate(notation) == nil)
    }

    @Test func notationRoundTrips() {
        for row in 0..<26 {
            for column in 0..<26 {
                let coordinate = Coordinate(row: row, column: column)
                #expect(Coordinate(coordinate.notation) == coordinate)
            }
        }
    }

    @Test func encodesAsNotationString() throws {
        let data = try JSONEncoder().encode([Coordinate(row: 1, column: 6)])
        #expect(String(decoding: data, as: UTF8.self) == #"["B7"]"#)
        #expect(try JSONDecoder().decode([Coordinate].self, from: data) == [Coordinate(row: 1, column: 6)])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([Coordinate].self, from: Data(#"["nope"]"#.utf8))
        }
    }

    @Test func ordersRowMajor() {
        let sorted = ["B1", "A2", "A1", "C10"].compactMap(Coordinate.init).sorted()
        #expect(sorted.map(\.notation) == ["A1", "A2", "B1", "C10"])
    }
}

@Suite("Ship placements")
struct ShipPlacementTests {
    @Test func horizontalShipCoversCellsToTheRight() {
        let ship = ShipPlacement(kind: .cruiser, origin: Coordinate("C4")!, orientation: .horizontal)
        #expect(ship.cells.map(\.notation) == ["C4", "C5", "C6"])
        #expect(ship.end == Coordinate("C6"))
        #expect(ship.contains(Coordinate("C5")!))
        #expect(!ship.contains(Coordinate("D5")!))
        #expect(ship.segmentIndex(of: Coordinate("C6")!) == 2)
        #expect(ship.segmentIndex(of: Coordinate("C7")!) == nil)
    }

    @Test func verticalShipCoversCellsBelow() {
        let ship = ShipPlacement(kind: .destroyer, origin: Coordinate("H10")!, orientation: .vertical)
        #expect(ship.cells.map(\.notation) == ["H10", "I10"])
        #expect(ship.rotated().cells.map(\.notation) == ["H10", "H11"])
    }

    @Test func detectsOverlap() {
        let a = ShipPlacement(kind: .carrier, origin: Coordinate("A1")!, orientation: .horizontal)
        let crossing = ShipPlacement(kind: .submarine, origin: Coordinate("A3")!, orientation: .vertical)
        let touching = ShipPlacement(kind: .submarine, origin: Coordinate("B1")!, orientation: .horizontal)
        #expect(a.overlaps(crossing))
        #expect(!a.overlaps(touching))
    }

    @Test func encodesReadably() throws {
        let ship = ShipPlacement(kind: .patrolBoat, origin: Coordinate("E5")!, orientation: .vertical)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(ship), as: UTF8.self)
        #expect(json == #"{"kind":"patrolBoat","orientation":"vertical","origin":"E5"}"#)
    }
}

@Suite("Rules")
struct RulesTests {
    static let classicFleet: [ShipPlacement] = [
        ShipPlacement(kind: .carrier, origin: Coordinate("A1")!, orientation: .horizontal),
        ShipPlacement(kind: .battleship, origin: Coordinate("B1")!, orientation: .horizontal),
        ShipPlacement(kind: .cruiser, origin: Coordinate("C1")!, orientation: .horizontal),
        ShipPlacement(kind: .submarine, origin: Coordinate("D1")!, orientation: .horizontal),
        ShipPlacement(kind: .destroyer, origin: Coordinate("E1")!, orientation: .horizontal),
    ]

    @Test func acceptsLegalFleet() throws {
        try Rules.classic.validate(Self.classicFleet)
        try Rules.classic.validate(Self.classicFleet.reversed())
    }

    @Test func rejectsWrongShips() {
        var fleet = Self.classicFleet
        fleet.removeLast()
        #expect(throws: FleetError.self) { try Rules.classic.validate(fleet) }

        fleet.append(ShipPlacement(kind: .cruiser, origin: Coordinate("J1")!, orientation: .horizontal))
        #expect(!Rules.classic.isValid(fleet), "two cruisers and no destroyer")
    }

    @Test func rejectsShipsOffTheBoard() {
        var fleet = Self.classicFleet
        fleet[0] = ShipPlacement(kind: .carrier, origin: Coordinate("A7")!, orientation: .horizontal)
        #expect(throws: FleetError.outOfBounds(fleet[0])) { try Rules.classic.validate(fleet) }
    }

    @Test func rejectsOverlappingShips() {
        var fleet = Self.classicFleet
        fleet[4] = ShipPlacement(kind: .destroyer, origin: Coordinate("A10")!, orientation: .vertical)
        #expect(Rules.classic.isValid(fleet))
        fleet[4] = ShipPlacement(kind: .destroyer, origin: Coordinate("A2")!, orientation: .vertical)
        #expect(throws: FleetError.overlap(Coordinate("A2")!)) { try Rules.classic.validate(fleet) }
    }

    @Test func quickModeIsTheOriginalGame() {
        #expect(GameMode.quick.rules.boardSize == 5)
        #expect(GameMode.quick.rules.fleet == Array(repeating: .patrolBoat, count: 5))
        #expect(Rules.quick.possiblePlacements(of: .patrolBoat).count == 25)
    }

    @Test func countsPossiblePlacements() {
        // A 5-long ship fits in 6 positions per row, 10 rows, two orientations.
        #expect(Rules.classic.possiblePlacements(of: .carrier).count == 120)
        #expect(Rules.classic.possiblePlacements(of: .destroyer).count == 180)
    }

    @Test(arguments: GameMode.allCases)
    func randomFleetsAreAlwaysLegal(mode: GameMode) throws {
        var generator = SeededRandomNumberGenerator(seed: 42)
        var seen = Set<[ShipPlacement]>()
        for _ in 0..<200 {
            let fleet = mode.rules.randomFleet(using: &generator)
            try mode.rules.validate(fleet)
            seen.insert(fleet)
        }
        #expect(seen.count > 150, "random fleets should vary")
    }

    @Test func randomFleetSolvesTightBoards() throws {
        // Only a handful of arrangements exist; backtracking must find one.
        let tight = Rules(boardSize: 3, fleet: [.cruiser, .cruiser, .cruiser])
        var generator = SeededRandomNumberGenerator(seed: 7)
        for _ in 0..<20 {
            try tight.validate(tight.randomFleet(using: &generator))
        }
    }
}
