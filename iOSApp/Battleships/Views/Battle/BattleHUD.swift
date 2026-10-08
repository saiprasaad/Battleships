import BattleshipCore
import SwiftUI

/// The instrument panel at the top of a battle: whose turn it is in big lit letters, both fleets
/// at a glance and, on iPhone, a miniature of the player's own waters.
struct BattleHUD<MiniMap: View>: View {
    let perspective: BattlePerspective
    let headline: String
    let statusLine: String
    let mood: BattleController.Mood
    /// Wide layouts spread out in a row and leave the miniature out.
    var isWide = false
    @ViewBuilder let miniMap: () -> MiniMap

    var body: some View {
        Group {
            if isWide {
                HStack(alignment: .center, spacing: 24) {
                    headlineStack
                    Spacer(minLength: 16)
                    rosters
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        headlineStack
                        Spacer(minLength: 0)
                        rosters
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    miniMap()
                }
                // Lets the rosters settle at the bottom, level with the miniature's caption.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .hudPanel()
    }

    private var headlineStack: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                PulsingDot(color: mood.color, isPulsing: mood == .waiting || mood == .danger)
                Text(headline.uppercased())
                    .font(.display(22))
                    .foregroundStyle(mood.color)
                    .glow(mood.color, radius: 10)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.interpolate)
            }
            Text(statusLine)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.snappy, value: headline)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var rosters: some View {
        VStack(alignment: .leading, spacing: 8) {
            FleetRoster(title: "You", spokenTitle: "Your fleet", ships: RosterShip.mine(in: perspective), tint: Theme.hull)
            FleetRoster(title: "Enemy", spokenTitle: "Enemy fleet", ships: RosterShip.enemy(in: perspective), tint: Theme.hit)
        }
    }
}

extension BattleController.Mood {
    var color: Color {
        switch self {
        case .neutral: .white
        case .ready: Theme.reticle
        case .waiting: Theme.amber
        case .danger: Theme.hit
        case .triumph: Theme.gold
        case .defeat: Theme.hit
        }
    }
}

/// One ship in a fleet roster.
struct RosterShip: Identifiable, Hashable {
    let id: Int
    let kind: ShipKind
    let isSunk: Bool

    static func mine(in perspective: BattlePerspective) -> [RosterShip] {
        var remaining = perspective.myFleet
        var roster: [RosterShip] = []
        for kind in perspective.rules.fleet {
            guard let index = remaining.firstIndex(where: { $0.kind == kind }) else { continue }
            let ship = remaining.remove(at: index)
            roster.append(RosterShip(id: roster.count, kind: kind, isSunk: perspective.isSunk(ship)))
        }
        return roster
    }

    /// The enemy's fleet, with the ships sunk so far crossed off.
    static func enemy(in perspective: BattlePerspective) -> [RosterShip] {
        var sunk = perspective.knownEnemyShips.filter { perspective.isSunk($0) }.map(\.kind)
        var roster: [RosterShip] = []
        for (index, kind) in perspective.rules.fleet.enumerated() {
            if let match = sunk.firstIndex(of: kind) {
                sunk.remove(at: match)
                roster.append(RosterShip(id: index, kind: kind, isSunk: true))
            } else {
                roster.append(RosterShip(id: index, kind: kind, isSunk: false))
            }
        }
        return roster
    }
}

/// A row of hull silhouettes, one per ship, crossed out once sunk.
struct FleetRoster: View {
    let title: String
    let spokenTitle: String
    let ships: [RosterShip]
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(1)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(ships) { ship in
                    RosterPip(kind: ship.kind, isSunk: ship.isSunk, tint: tint)
                }
            }
            .animation(.spring(duration: 0.4), value: ships)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenTitle)
        .accessibilityValue("\(ships.filter { !$0.isSunk }.count) of \(ships.count) ships afloat")
    }
}

private struct RosterPip: View {
    let kind: ShipKind
    let isSunk: Bool
    let tint: Color

    var body: some View {
        HullShape(kind: kind)
            .fill(isSunk ? AnyShapeStyle(Color.white.opacity(0.1)) : AnyShapeStyle(tint.gradient))
            .overlay {
                if isSunk {
                    Capsule()
                        .fill(Theme.hit)
                        .frame(height: 1.5)
                        .rotationEffect(.degrees(-10))
                }
            }
            .frame(width: max(11, CGFloat(kind.length) * 7), height: 8)
            .shadow(color: isSunk ? .clear : tint.opacity(0.5), radius: 3)
    }
}

/// The player's own board in miniature. Tapping it opens the full-size view.
struct MiniMapButton: View {
    let perspective: BattlePerspective
    let effects: [ImpactEffect]
    let isUnderFire: Bool
    let hitsTaken: Int
    let action: @MainActor () -> Void

    var body: some View {
        Button { action() } label: {
            VStack(spacing: 6) {
                HomeBoard(perspective: perspective, effects: effects, isMiniature: true, isUnderFire: isUnderFire)
                    .frame(width: 106, height: 106)
                    .shakes(on: hitsTaken, amplitude: 4)
                HStack(spacing: 4) {
                    Text("YOUR FLEET")
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your fleet")
        .accessibilityValue("\(perspective.myShipsRemaining) of \(perspective.myFleet.count) ships afloat")
        .accessibilityHint("Shows your board full size.")
    }
}

/// The player's board at full size, with the state of each ship, while the battle goes on.
struct FleetSheet: View {
    let controller: BattleController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                OceanBackdrop()
                if let perspective = controller.perspective {
                    ScrollView {
                        VStack(spacing: 20) {
                            HomeBoard(
                                perspective: perspective,
                                effects: controller.effects,
                                isUnderFire: controller.mood == .danger
                            )
                            .shakes(on: controller.hitsTaken)
                            .frame(maxWidth: 520)

                            ShipStatusList(perspective: perspective)
                                .frame(maxWidth: 520)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Your Fleet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct ShipStatusList: View {
    let perspective: BattlePerspective

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(perspective.myFleet.enumerated()), id: \.offset) { index, ship in
                if index > 0 {
                    Divider()
                }
                ShipStatusRow(
                    kind: ship.kind,
                    hits: ship.cells.filter { perspective.homeMark(at: $0) != nil }.count,
                    isSunk: perspective.isSunk(ship)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .hudPanel(cornerRadius: 18)
    }
}

private struct ShipStatusRow: View {
    let kind: ShipKind
    let hits: Int
    let isSunk: Bool

    var body: some View {
        HStack(spacing: 14) {
            ShipView(ship: ShipPlacement(kind: kind, origin: Coordinate(row: 0, column: 0), orientation: .horizontal), isSunk: isSunk)
                .frame(width: CGFloat(kind.length) * 18, height: 15)
                .frame(width: 92, alignment: .leading)
                .accessibilityHidden(true)
            Text(kind.displayName)
                .font(.body.weight(.semibold))
            Spacer(minLength: 8)
            Text(status)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        if isSunk { return "Sunk" }
        return hits > 0 ? "\(hits) of \(kind.length) hit" : "Afloat"
    }

    private var statusColor: Color {
        if isSunk { return Theme.hit }
        return hits > 0 ? Theme.amber : Theme.victory
    }
}
