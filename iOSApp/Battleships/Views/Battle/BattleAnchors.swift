import BattleshipCore
import SwiftUI

/// The battle's landmarks, published up the view tree so an effect drawn above everything (the shell's
/// arc from the Fire button to the aimed cell, the incoming streak onto the player's waters) can aim at
/// them. Anchors re-resolve every frame, so a layout change mid-flight re-aims the arc.
///
/// `TargetBoard` publishes `.targetBoard` and `.targetCell(aim)` over the aimed cell; `HomeBoard`
/// publishes `.homeBoard` and `.homeCell` on the cell the enemy's shell is heading for (or the latest
/// one it struck); the HUD publishes `.homeSurface` for whichever of the board, the mini map or the
/// tile shows the player's waters, `.fireButton` and `.hudDot`.
enum BattleAnchor: Hashable, Sendable {
    case fireButton
    case targetBoard
    case targetCell(Coordinate)
    /// The full-size home board.
    case homeBoard
    /// Whichever view shows the player's waters in the current layout: the board, the mini map or the tile.
    case homeSurface
    case homeCell(Coordinate)
    case hudDot
}

/// Read them with `overlayPreferenceValue(BattleAnchors.self) { anchors in GeometryReader { proxy in … proxy[anchor] … } }`.
struct BattleAnchors: PreferenceKey {
    static var defaultValue: [BattleAnchor: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [BattleAnchor: Anchor<CGRect>], nextValue: () -> [BattleAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, newer in newer }
    }
}

extension View {
    /// Publishes this view's bounds as `key` for the battle's overlays to aim at.
    func battleAnchor(_ key: BattleAnchor) -> some View {
        anchorPreference(key: BattleAnchors.self, value: .bounds) { [key: $0] }
    }

    /// The same, publishing nothing for `nil` (a miniature that isn't the home surface, say).
    func battleAnchor(_ key: BattleAnchor?) -> some View {
        anchorPreference(key: BattleAnchors.self, value: .bounds) { anchor in
            key.map { [$0: anchor] } ?? [:]
        }
    }
}
