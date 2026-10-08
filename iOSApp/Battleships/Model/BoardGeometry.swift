import BattleshipCore
import Foundation

/// Maps board coordinates to points on a square board drawn `side` points wide, leaving a gutter
/// along the top and left for the column numbers and row letters.
struct BoardGeometry: Equatable, Sendable {
    let boardSize: Int
    let gutter: CGFloat
    let cell: CGFloat

    init(boardSize: Int, side: CGFloat, showsLabels: Bool) {
        self.boardSize = boardSize
        gutter = showsLabels ? max(14, side * 0.055) : 0
        cell = max(0, side - gutter) / CGFloat(boardSize)
    }

    var gridSide: CGFloat { cell * CGFloat(boardSize) }

    var gridRect: CGRect {
        CGRect(x: gutter, y: gutter, width: gridSide, height: gridSide)
    }

    func rect(for coordinate: Coordinate) -> CGRect {
        CGRect(
            x: gutter + CGFloat(coordinate.column) * cell,
            y: gutter + CGFloat(coordinate.row) * cell,
            width: cell,
            height: cell
        )
    }

    func center(of coordinate: Coordinate) -> CGPoint {
        let rect = rect(for: coordinate)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func rect(for ship: ShipPlacement) -> CGRect {
        rect(for: ship.origin).union(rect(for: ship.end))
    }

    /// The cell under `point`, if any.
    func coordinate(at point: CGPoint) -> Coordinate? {
        guard cell > 0 else { return nil }
        let column = Int(((point.x - gutter) / cell).rounded(.down))
        let row = Int(((point.y - gutter) / cell).rounded(.down))
        guard (0..<boardSize).contains(row), (0..<boardSize).contains(column) else { return nil }
        return Coordinate(row: row, column: column)
    }
}
