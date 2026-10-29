import BattleshipCore
import SwiftUI

/// The enemy's waters: where the player aims and fires.
struct TargetBoard: View {
    let perspective: BattlePerspective
    let aimed: Coordinate?
    /// The battle's direction: the shells in the air and the effects on this board.
    let controller: BattleController
    let isInteractive: Bool
    let onTap: @MainActor (Coordinate) -> Void

    var body: some View {
        // The aim shows only while the player can fire, so it doesn't linger once the game ends.
        let aim = isInteractive ? aimed : nil
        BoardView(
            rules: perspective.rules,
            highlighted: aim,
            accent: isInteractive ? Theme.reticle : nil,
            isDimmed: !isInteractive && !perspective.isFinished
        ) { geometry in
            if let aim {
                AimGuides(geometry: geometry, target: aim)
                    .transition(.opacity)
            }

            ForEach(perspective.knownEnemyShips, id: \.self) { ship in
                let rect = geometry.rect(for: ship).insetBy(dx: geometry.cell * 0.1, dy: geometry.cell * 0.1)
                ShipView(ship: ship, isSunk: perspective.isEnemyShipSunk(ship))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .transition(.scale(scale: 1.4).combined(with: .opacity))
                    .accessibilityHidden(true)
            }

            // A cell's result stays a secret while its shell is in the air.
            let hidden = controller.cellsAwaitingLanding(on: .target, at: Date())
            let shots = perspective.myShots.filter { !hidden.contains($0.target) }
            ForEach(shots.filter { !$0.result.isHit }, id: \.target) { move in
                if let mark = perspective.targetMark(at: move.target) {
                    CellMarkView(mark: mark, cell: geometry.cell)
                        .position(geometry.center(of: move.target))
                }
            }
            FlameClock(isBurning: shots.contains { $0.result.isHit }) { time in
                ForEach(shots.filter { $0.result.isHit }, id: \.target) { move in
                    if let mark = perspective.targetMark(at: move.target) {
                        CellMarkView(mark: mark, cell: geometry.cell, showsHitGlow: mark == .hit, time: time)
                            .position(geometry.center(of: move.target))
                    }
                }
            }

            if let aim {
                ReticleView(cell: geometry.cell, target: aim)
                    .position(geometry.center(of: aim))
                    .transition(.scale(scale: 1.6).combined(with: .opacity))
            }

            EffectsLayer(geometry: geometry, board: .target, controller: controller)

            if let aim {
                Color.clear
                    .frame(width: geometry.cell, height: geometry.cell)
                    .battleAnchor(.targetCell(aim))
                    .position(geometry.center(of: aim))
                    .allowsHitTesting(false)
            }

            CellTargets(geometry: geometry, rules: perspective.rules) { coordinate in
                CellTargets.Description(
                    value: targetDescription(at: coordinate, aim: aim),
                    hint: isInteractive && perspective.canTarget(coordinate)
                        ? (aim == coordinate ? "Double-tap to fire." : "Double-tap to aim here.")
                        : nil
                )
            } onTap: { coordinate in
                if isInteractive {
                    onTap(coordinate)
                }
            }
        }
        .battleAnchor(.targetBoard)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: aim)
        .animation(.easeOut(duration: 0.5), value: perspective.knownEnemyShips)
        .animation(.easeInOut(duration: 0.4), value: isInteractive)
    }

    private func targetDescription(at coordinate: Coordinate, aim: Coordinate?) -> String {
        switch perspective.targetMark(at: coordinate) {
        case .miss: return "Miss"
        case .hit: return "Hit"
        case .sunk:
            let kind = perspective.knownEnemyShip(at: coordinate)?.kind.displayName ?? "ship"
            return "Sunk \(kind)"
        case nil:
            if let ship = perspective.knownEnemyShip(at: coordinate) {
                return "Enemy \(ship.kind.displayName), not hit"
            }
            return aim == coordinate ? "Aimed, not fired at yet" : "Not fired at yet"
        }
    }
}

/// The player's own waters: their fleet and the enemy's shots against it.
struct HomeBoard: View {
    let perspective: BattlePerspective
    /// The battle's direction: the enemy's telegraphed shell and the effects on this board.
    let controller: BattleController
    /// The miniature in the battle header has no labels and is a single button, not 100 cells.
    var isMiniature = false
    /// The enemy is lining up a shot: a red sweep crosses the water.
    var isUnderFire = false

    var body: some View {
        BoardView(rules: perspective.rules, showsLabels: !isMiniature) { geometry in
            ForEach(perspective.myFleet, id: \.self) { ship in
                let rect = geometry.rect(for: ship).insetBy(dx: geometry.cell * 0.1, dy: geometry.cell * 0.1)
                ShipView(ship: ship, isSunk: perspective.isMyShipSunk(ship))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .accessibilityHidden(true)
            }

            // The enemy's result stays a secret until its telegraphed shell lands.
            let hidden = controller.cellsAwaitingLanding(on: .home, at: Date())
            let shots = perspective.enemyShots.filter { !hidden.contains($0.target) }
            ForEach(shots.filter { !$0.result.isHit }, id: \.target) { move in
                if let mark = perspective.homeMark(at: move.target) {
                    CellMarkView(mark: mark, cell: geometry.cell, isMiniature: isMiniature)
                        .position(geometry.center(of: move.target))
                }
            }
            // The miniature draws hits as dots, which don't flicker.
            FlameClock(isBurning: !isMiniature && shots.contains { $0.result.isHit }) { time in
                ForEach(shots.filter { $0.result.isHit }, id: \.target) { move in
                    if let mark = perspective.homeMark(at: move.target) {
                        CellMarkView(mark: mark, cell: geometry.cell, isMiniature: isMiniature, time: time)
                            .position(geometry.center(of: move.target))
                    }
                }
            }

            if isUnderFire {
                SonarSweep(tint: Theme.hit, period: 2.4)
                    .frame(width: geometry.gridSide, height: geometry.gridSide)
                    .clipShape(RoundedRectangle(cornerRadius: min(14, geometry.cell * 0.35), style: .continuous))
                    .position(x: geometry.gridRect.midX, y: geometry.gridRect.midY)
                    .transition(.opacity)
            }

            EffectsLayer(geometry: geometry, board: .home, controller: controller, isMiniature: isMiniature)

            if !isMiniature, let awaited = controller.telegraph?.coordinate ?? controller.latestEnemyShot {
                Color.clear
                    .frame(width: geometry.cell, height: geometry.cell)
                    .battleAnchor(.homeCell(awaited))
                    .position(geometry.center(of: awaited))
                    .allowsHitTesting(false)
            }

            if !isMiniature {
                CellTargets(geometry: geometry, rules: perspective.rules) { coordinate in
                    CellTargets.Description(value: homeDescription(at: coordinate), hint: nil)
                } onTap: { _ in }
            }
        }
        .battleAnchor(isMiniature ? nil : .homeBoard)
        .animation(.easeInOut(duration: 0.5), value: isUnderFire)
    }

    private func homeDescription(at coordinate: Coordinate) -> String {
        let ship = perspective.myShip(at: coordinate)
        switch (perspective.homeMark(at: coordinate), ship) {
        case (.miss, _): return "Enemy miss"
        case let (.hit, ship?): return "Your \(ship.kind.displayName), hit"
        case let (.sunk, ship?): return "Your \(ship.kind.displayName), sunk"
        case let (nil, ship?): return "Your \(ship.kind.displayName)"
        default: return "Open water"
        }
    }
}

/// Invisible, accessible tap targets, one per cell, so VoiceOver can explore the board square by square.
struct CellTargets: View {
    struct Description {
        let value: String
        let hint: String?
    }

    let geometry: BoardGeometry
    let rules: Rules
    let describe: @MainActor (Coordinate) -> Description
    let onTap: @MainActor (Coordinate) -> Void

    var body: some View {
        ForEach(rules.allCoordinates, id: \.self) { coordinate in
            let rect = geometry.rect(for: coordinate)
            let description = describe(coordinate)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .onTapGesture { onTap(coordinate) }
                .accessibilityElement()
                .accessibilityLabel(coordinate.notation)
                .accessibilityValue(description.value)
                .accessibilityHint(description.hint ?? "")
                .accessibilityAddTraits(description.hint == nil ? [] : .isButton)
                .accessibilityAction { onTap(coordinate) }
        }
    }
}

private extension BattleController {
    /// The cells on `board` whose result is still a secret at `now`: a shell for them is in the air
    /// (held at the apex, or landing later), or the enemy's telegraphed shell hasn't landed yet. The
    /// boards draw no mark there until it has.
    func cellsAwaitingLanding(on board: BoardSide, at now: Date) -> Set<Coordinate> {
        var cells = Set<Coordinate>()
        for shell in shells where shell.board == board && shell.outcome != .misfire {
            if let lands = shell.lands, lands <= now {
                continue
            }
            cells.insert(shell.coordinate)
        }
        if board == .home, let telegraph, telegraph.lands > now {
            cells.insert(telegraph.coordinate)
        }
        return cells
    }
}
