import BattleshipCore
import SwiftUI

/// The enemy's waters: where the player aims and fires.
struct TargetBoard: View {
    let perspective: BattlePerspective
    let aimed: Coordinate?
    let effects: [ImpactEffect]
    let isInteractive: Bool
    let onTap: @MainActor (Coordinate) -> Void

    var body: some View {
        BoardView(rules: perspective.rules) { geometry in
            ForEach(perspective.knownEnemyShips, id: \.self) { ship in
                let rect = geometry.rect(for: ship).insetBy(dx: geometry.cell * 0.1, dy: geometry.cell * 0.1)
                ShipView(ship: ship, isSunk: perspective.isSunk(ship))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .transition(.scale.combined(with: .opacity))
            }

            ForEach(perspective.myShots, id: \.target) { move in
                if let mark = perspective.targetMark(at: move.target) {
                    CellMarkView(mark: mark, cell: geometry.cell, showsHitGlow: mark == .hit)
                        .position(geometry.center(of: move.target))
                }
            }

            if let aimed {
                ReticleView(cell: geometry.cell)
                    .position(geometry.center(of: aimed))
            }

            ForEach(effects.filter { $0.board == .target }) { effect in
                ImpactView(isHit: effect.isHit, cell: geometry.cell)
                    .position(geometry.center(of: effect.coordinate))
            }

            CellTargets(geometry: geometry, rules: perspective.rules) { coordinate in
                CellTargets.Description(
                    value: targetDescription(at: coordinate),
                    hint: isInteractive && perspective.canTarget(coordinate)
                        ? (aimed == coordinate ? "Double-tap to fire." : "Double-tap to aim here.")
                        : nil
                )
            } onTap: { coordinate in
                if isInteractive {
                    onTap(coordinate)
                }
            }
        }
        .animation(.spring(duration: 0.3), value: aimed)
        .animation(.easeOut(duration: 0.4), value: perspective.knownEnemyShips)
    }

    private func targetDescription(at coordinate: Coordinate) -> String {
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
            return aimed == coordinate ? "Aimed, not fired at yet" : "Not fired at yet"
        }
    }
}

/// The player's own waters: their fleet and the enemy's shots against it.
struct HomeBoard: View {
    let perspective: BattlePerspective
    let effects: [ImpactEffect]

    var body: some View {
        BoardView(rules: perspective.rules) { geometry in
            ForEach(perspective.myFleet, id: \.self) { ship in
                let rect = geometry.rect(for: ship).insetBy(dx: geometry.cell * 0.1, dy: geometry.cell * 0.1)
                ShipView(ship: ship, isSunk: perspective.isSunk(ship))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }

            ForEach(perspective.enemyShots, id: \.target) { move in
                if let mark = perspective.homeMark(at: move.target) {
                    CellMarkView(mark: mark, cell: geometry.cell)
                        .position(geometry.center(of: move.target))
                }
            }

            ForEach(effects.filter { $0.board == .home }) { effect in
                ImpactView(isHit: effect.isHit, cell: geometry.cell)
                    .position(geometry.center(of: effect.coordinate))
            }

            CellTargets(geometry: geometry, rules: perspective.rules) { coordinate in
                CellTargets.Description(value: homeDescription(at: coordinate), hint: nil)
            } onTap: { _ in }
        }
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

/// Lets the player drag ships into position and tap them to turn them.
struct PlacementBoard: View {
    let model: FleetPlacementModel
    let feedback: any FeedbackPlayer

    private struct Drag: Equatable {
        let index: Int
        var translation: CGSize
        var candidate: ShipPlacement
        var fits: Bool
    }

    @State private var drag: Drag?

    var body: some View {
        BoardView(rules: model.rules) { geometry in
            if let drag {
                let rect = geometry.rect(for: drag.candidate).insetBy(dx: 2, dy: 2)
                RoundedRectangle(cornerRadius: geometry.cell * 0.3, style: .continuous)
                    .fill((drag.fits ? Theme.victory : Theme.hit).opacity(0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: geometry.cell * 0.3, style: .continuous)
                            .strokeBorder(drag.fits ? Theme.victory : Theme.hit, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }

            ForEach(model.ships.indices, id: \.self) { index in
                ship(at: index, geometry: geometry)
            }
        }
    }

    @ViewBuilder
    private func ship(at index: Int, geometry: BoardGeometry) -> some View {
        let ship = model.ships[index]
        let rect = geometry.rect(for: ship).insetBy(dx: geometry.cell * 0.08, dy: geometry.cell * 0.08)
        let isDragging = drag?.index == index

        ShipView(ship: ship, isHighlighted: isDragging || model.selectedIndex == index)
            .frame(width: rect.width, height: rect.height)
            .scaleEffect(isDragging ? 1.06 : 1)
            .contentShape(Rectangle())
            .onTapGesture { rotate(index) }
            .gesture(dragGesture(for: index, geometry: geometry))
            .offset(isDragging ? drag?.translation ?? .zero : .zero)
            .position(x: rect.midX, y: rect.midY)
            .zIndex(isDragging ? 1 : 0)
            .accessibilityElement()
            .accessibilityLabel("\(ship.kind.displayName), \(ship.length) squares")
            .accessibilityValue("\(ship.orientation == .horizontal ? "Horizontal" : "Vertical"), from \(ship.origin.notation) to \(ship.end.notation)")
            .accessibilityHint("Double-tap to turn. Swipe up or down for more actions.")
            .accessibilityAction { rotate(index) }
            .accessibilityAction(named: "Move up") { nudge(index, rows: -1) }
            .accessibilityAction(named: "Move down") { nudge(index, rows: 1) }
            .accessibilityAction(named: "Move left") { nudge(index, columns: -1) }
            .accessibilityAction(named: "Move right") { nudge(index, columns: 1) }
    }

    private func dragGesture(for index: Int, geometry: BoardGeometry) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let ship = model.ships[index]
                let columns = Int((value.translation.width / geometry.cell).rounded())
                let rows = Int((value.translation.height / geometry.cell).rounded())
                let candidate = ship.moved(to: ship.origin.offsetBy(rows: rows, columns: columns))
                if drag == nil {
                    model.selectedIndex = index
                    feedback.play(.select)
                } else if drag?.candidate != candidate {
                    feedback.play(.select)
                }
                drag = Drag(index: index, translation: value.translation, candidate: candidate, fits: model.canPlace(candidate, replacing: index))
            }
            .onEnded { _ in
                guard let finished = drag else { return }
                withAnimation(.spring(duration: 0.3, bounce: 0.25)) {
                    if finished.fits {
                        model.move(index, to: finished.candidate.origin)
                    }
                    drag = nil
                }
                feedback.play(finished.fits ? .place : .invalid)
            }
    }

    private func rotate(_ index: Int) {
        withAnimation(.spring(duration: 0.3, bounce: 0.3)) {
            model.selectedIndex = index
            feedback.play(model.rotate(index) ? .place : .invalid)
        }
    }

    private func nudge(_ index: Int, rows: Int = 0, columns: Int = 0) {
        withAnimation(.spring(duration: 0.25)) {
            feedback.play(model.nudge(index, rows: rows, columns: columns) ? .place : .invalid)
        }
    }
}
