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
        ScrollView {
            VStack(spacing: 20) {
                Text("Drag a ship to move it. Tap it to turn it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                PlacementBoard(model: model, feedback: app.feedback)
                    .frame(maxWidth: 520)

                FleetLegend(rules: mode.rules)
            }
            .padding()
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                        model.shuffle()
                    }
                    app.feedback.play(.place)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
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
                    .frame(maxWidth: .infinity)
                }
                .primaryActionStyle()
                .controlSize(.large)
                .disabled(isSubmitting || !model.isValid)
            }
            .padding()
            .background(.bar)
        }
        .navigationTitle("Deploy Your Fleet")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The ships in this mode's fleet and their sizes.
struct FleetLegend: View {
    let rules: Rules

    var body: some View {
        let counts = Dictionary(grouping: rules.fleet, by: { $0 })
        let kinds = rules.fleet.reduce(into: [ShipKind]()) { kinds, kind in
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("Your fleet")
                .font(.headline)
            ForEach(kinds, id: \.self) { kind in
                HStack(spacing: 12) {
                    HStack(spacing: 2) {
                        ForEach(0..<kind.length, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.hullShadow)
                                .frame(width: 14, height: 14)
                        }
                    }
                    .frame(width: 5 * 16, alignment: .leading)
                    Text(kind.displayName)
                    Spacer()
                    if let count = counts[kind]?.count, count > 1 {
                        Text("×\(count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .font(.subheadline)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(counts[kind]?.count ?? 1) \(kind.displayName), \(kind.length) squares")
            }
        }
        .padding()
        .frame(maxWidth: 520, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
