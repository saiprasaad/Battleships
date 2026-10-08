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
                    Label("Drag a ship to move it. Tap it to turn it.", systemImage: "hand.draw")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    PlacementBoard(model: model, feedback: app.feedback)
                        .frame(maxWidth: 520)

                    FleetLegend(rules: mode.rules)
                        .frame(maxWidth: 520)
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
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
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(1.6)
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
                Text(kind.length == 1 ? "1 square" : "\(kind.length) squares")
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
        .accessibilityLabel("\(count) \(kind.displayName), \(kind.length) squares")
    }
}
