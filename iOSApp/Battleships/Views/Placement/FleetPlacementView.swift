import BattleshipCore
import SwiftUI

/// Arrange your fleet before a battle. The fleet starts in a random legal layout, so a player in a
/// hurry can just press the button.
struct FleetPlacementView: View {
    let mode: GameMode
    let confirmTitle: String
    let onConfirm: @MainActor ([ShipPlacement]) async -> Void

    @Environment(AppModel.self) private var app
    @State private var model: FleetPlacementModel
    @State private var isSubmitting = false
    @State private var isDraggingShip = false

    init(mode: GameMode, confirmTitle: String, onConfirm: @escaping @MainActor ([ShipPlacement]) async -> Void) {
        self.mode = mode
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        _model = State(initialValue: FleetPlacementModel(rules: mode.rules))
    }

    var body: some View {
        ZStack {
            OceanBackdrop()
            ScrollView {
                VStack(spacing: 20) {
                    Label(instructions, systemImage: "hand.draw")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)

                    PlacementBoard(model: model, feedback: app.feedback, isDragging: $isDraggingShip)
                        .frame(maxWidth: 520)

                    FleetLegend(rules: mode.rules)
                        .frame(maxWidth: 520)
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Holds the screen still under a ship being dragged.
            .scrollDisabled(isDraggingShip)
        }
        .safeAreaInset(edge: .bottom) {
            controls
        }
        .environment(\.colorScheme, .dark)
        .navigationTitle("Deploy Your Fleet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Theme.abyss.opacity(0.4), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    /// One-square boats look the same either way round, so they can't be turned.
    private var instructions: String {
        mode.rules.fleet.contains { $0.length > 1 }
            ? "Drag a ship to move it. Tap it to turn it."
            : "Drag a boat to move it."
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(duration: 0.45, bounce: 0.25)) {
                    model.shuffle()
                }
                app.feedback.play(.place)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .controlSize(.large)

            Button {
                Task {
                    isSubmitting = true
                    await onConfirm(model.ships)
                    isSubmitting = false
                }
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Label(confirmTitle, systemImage: "flag.checkered")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .primaryActionStyle()
            .tint(Theme.hit)
            .controlSize(.large)
            .disabled(isSubmitting || !model.isValid)
        }
        .padding(14)
        .hudPanel(cornerRadius: 28)
        .padding(.horizontal)
        .padding(.bottom, 6)
        .frame(maxWidth: 560)
    }
}

/// The ships in this mode's fleet and their sizes.
struct FleetLegend: View {
    let rules: Rules

    var body: some View {
        let counts = Dictionary(grouping: rules.fleet, by: { $0 }).mapValues(\.count)
        let kinds = rules.fleet.reduce(into: [ShipKind]()) { kinds, kind in
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR FLEET")
                .tracking(1.6)
                .scaledFont(12, weight: .heavy, design: .rounded, relativeTo: .caption)
                .foregroundStyle(.white.opacity(0.72))
                .accessibilityAddTraits(.isHeader)
            ForEach(kinds, id: \.self) { kind in
                FleetLegendRow(kind: kind, count: counts[kind] ?? 1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel(cornerRadius: 20)
    }
}

private struct FleetLegendRow: View {
    let kind: ShipKind
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            ShipView(ship: ShipPlacement(kind: kind, origin: Coordinate(row: 0, column: 0), orientation: .horizontal))
                .frame(width: CGFloat(kind.length) * 21, height: 17)
                .frame(width: 108, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.displayName)
                    .font(.body.weight(.semibold))
                Text(Phrase.count(kind.length, "square"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if count > 1 {
                Text("×\(count)")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.reticle)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenDescription)
    }

    /// "Carrier, 5 squares" or "5 Patrol Boats, 1 square each".
    private var spokenDescription: String {
        let size = Phrase.count(kind.length, "square")
        return count == 1 ? "\(kind.displayName), \(size)" : "\(count) \(kind.displayName)s, \(size) each"
    }
}
