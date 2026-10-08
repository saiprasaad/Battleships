/// A cell on the board.
///
/// Rows are lettered and columns are numbered from 1, so `Coordinate(row: 1, column: 6)`
/// is written "B7". Both indices are zero-based internally.
public struct Coordinate: Hashable, Sendable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    /// Parses board notation such as `"A1"` or `"j10"`. Returns `nil` for anything malformed.
    public init?(_ notation: String) {
        let scalars = Array(notation.uppercased().unicodeScalars)
        guard scalars.count >= 2, scalars.count <= 3,
              let letter = scalars.first, letter.value >= 65, letter.value <= 90
        else { return nil }

        let digits = scalars.dropFirst()
        guard digits.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
              digits.first?.value != 48, // no leading zeros: "A01" is not canonical
              let number = Int(String(String.UnicodeScalarView(digits)))
        else { return nil }

        self.init(row: Int(letter.value) - 65, column: number - 1)
    }

    /// Board notation, e.g. "B7".
    public var notation: String {
        Coordinate.rowLabel(row) + Coordinate.columnLabel(column)
    }

    /// The letter used for a row index (0 → "A").
    public static func rowLabel(_ row: Int) -> String {
        guard (0..<26).contains(row), let scalar = Unicode.Scalar(65 + row) else { return "?" }
        return String(Character(scalar))
    }

    /// The number used for a column index (0 → "1").
    public static func columnLabel(_ column: Int) -> String {
        String(column + 1)
    }

    public func offsetBy(rows: Int = 0, columns: Int = 0) -> Coordinate {
        Coordinate(row: row + rows, column: column + columns)
    }

    /// The four orthogonally adjacent cells. Some may lie off the board.
    public var orthogonalNeighbors: [Coordinate] {
        [offsetBy(rows: -1), offsetBy(rows: 1), offsetBy(columns: -1), offsetBy(columns: 1)]
    }
}

extension Coordinate: Comparable {
    public static func < (lhs: Coordinate, rhs: Coordinate) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

extension Coordinate: CustomStringConvertible {
    public var description: String { notation }
}

extension Coordinate: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let notation = try container.decode(String.self)
        guard let coordinate = Coordinate(notation) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "'\(notation)' is not a board coordinate like \"B7\"."
            )
        }
        self = coordinate
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(notation)
    }
}
