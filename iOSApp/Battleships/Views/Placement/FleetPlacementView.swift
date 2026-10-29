import BattleshipCore
import SwiftUI

/// Arrange your fleet before a battle. The fleet starts in a random legal layout, so a player in a
/// hurry can just press the button. The ships drop anchor as the screen appears (DEP-1) and cast off
/// when the fleet is confirmed (DEP-2), with the request running while they go.
struct FleetPlacementView: View {
    let mode: GameMode
    let confirmTitle: String
    /// Who the fleet will face, shown as a "vs" chip above the board when known (a rematch, a challenge).
    var opponentDisplayName: String? = nil
    /// Runs the request while the ships cast off; see `init(mode:confirmTitle:opponentDisplayName:director:onDeploy:)`.
    private let onDeploy: @MainActor ([ShipPlacement], DeployHandoff) async throws -> Void
    /// Turns ships and confirms the fleet from outside the gestures (the filmstrips).
    private let director: PlacementDirector?
    /// Off under a sheet's glass, where the screen behind does the moving; see `stillBackdrop()`.
    private var isBackdropAnimated = true

    @Environment(AppModel.self) private var app
    @Environment(\.motionPolicy) private var policy
    @State private var model: FleetPlacementModel
    @State private var isDraggingShip = false
    /// Bumped by the Shuffle button; the board does the shuffling.
    @State private var shuffles = 0
    /// Bumped by each confirmation, for the button's recoil.
    @State private var deploys = 0
    @State private var deploy = DeployPhase.idle
    @AccessibilityFocusState private var focusesInstructions: Bool

    /// `onConfirm` runs the request and whatever navigation follows it. It is called once the ships
    /// have cast off, since a hand-over it makes on its own can't wait for the departure; errors it
    /// throws sail the ships back and show a toast.
    init(
        mode: GameMode,
        confirmTitle: String,
        opponentDisplayName: String? = nil,
        director: PlacementDirector? = nil,
        onConfirm: @escaping @MainActor ([ShipPlacement]) async throws -> Void
    ) {
        self.init(mode: mode, confirmTitle: confirmTitle, opponentDisplayName: opponentDisplayName, director: director) { fleet, handoff in
            await handoff.departed()
            try await onConfirm(fleet)
        }
    }

    /// `onDeploy` runs the request while the ships cast off, and awaits `handoff.departed()` before
    /// it navigates, so the next screen arrives when both the departure and the request are done.
    /// Errors it throws sail the ships back and show a toast.
    init(
        mode: GameMode,
        confirmTitle: String,
        opponentDisplayName: String? = nil,
        director: PlacementDirector? = nil,
        onDeploy: @escaping @MainActor ([ShipPlacement], DeployHandoff) async throws -> Void
    ) {
        self.mode = mode
        self.confirmTitle = confirmTitle
        self.opponentDisplayName = opponentDisplayName
        self.director = director
        self.onDeploy = onDeploy
        _model = State(initialValue: FleetPlacementModel(rules: mode.rules))
    }

    /// The same screen with its ocean held still: for the accept sheet, whose glass sits over a battle
    /// that is already stilled beneath it, so one living backdrop at a time.
    func stillBackdrop() -> Self {
        var copy = self
        copy.isBackdropAnimated = false
        return copy
    }

    var body: some View {
        let isDeploying = deploy != .idle
        ZStack {
            OceanBackdrop(isAnimated: isBackdropAnimated)
            ScrollView {
                VStack(spacing: 20) {
                    if let opponentDisplayName {
                        DeployOpponentChip(name: opponentDisplayName)
                            // Stamps in once the fleet has dropped anchor.
                            .dropsAnchor(index: Timing.Stagger.maxItems, trigger: 0, curve: Motion.Curve.slam)
                    }

                    Label(instructions, systemImage: "hand.draw")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .opacity(isDeploying ? 0 : 1)
                        .animation(Motion.Curve.fade.policy(policy), value: isDeploying)
                        .accessibilityFocused($focusesInstructions)

                    PlacementBoard(
                        model: model,
                        feedback: app.feedback,
                        isDragging: $isDraggingShip,
                        shuffle: shuffles,
                        deploy: deploy,
                        director: director
                    )
                    .frame(maxWidth: 520)

                    FleetLegend(rules: mode.rules)
                        .frame(maxWidth: 520)
                        .opacity(isDeploying ? 0 : 1)
                        .animation(Motion.Curve.fade.policy(policy), value: isDeploying)
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
        .onAppear {
            app.setAmbientScene(.placement)
        }
        .task {
            // VoiceOver starts on the instructions once the fleet has dropped anchor (the lobby
            // announces the rematch before pushing this screen).
            try? await Task.sleep(for: .milliseconds(600))
            focusesInstructions = true
        }
        .onChange(of: director?.deploys) { confirm() }
    }

    /// One-square boats look the same either way round, so they can't be turned.
    private var instructions: String {
        mode.rules.fleet.contains { $0.length > 1 }
            ? "Drag a ship to move it. Tap it to turn it."
            : "Drag a boat to move it."
    }

    private var controls: some View {
        let isDeploying = deploy != .idle
        return HStack(spacing: 12) {
            Button {
                shuffles += 1
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .controlSize(.large)
            .disabled(isDeploying)

            Button {
                confirm()
            } label: {
                Group {
                    if isDeploying {
                        Text("Deploying…")
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
            .recoil(on: deploys, kick: 1.06)
            .disabled(isDeploying || !model.isValid)
            .accessibilityValue(isDeploying ? "Deploying fleet" : "")
        }
        .padding(14)
        .hudPanel(cornerRadius: 28)
        .padding(.horizontal)
        .padding(.bottom, 6)
        .frame(maxWidth: 560)
    }

    // MARK: Cast off

    private func confirm() {
        guard deploy == .idle, model.isValid else { return }
        deploys += 1
        app.feedback.play(.castOff)
        let fleet = model.ships
        let handoff = DeployHandoff()
        let request = onDeploy
        Task { @MainActor in
            await castOff(fleet, handoff: handoff, request: request)
        }
    }

    /// The lock, then the departure, with the request running alongside; then the hand-over, or the
    /// ships' return with a toast.
    private func castOff(
        _ fleet: [ShipPlacement],
        handoff: DeployHandoff,
        request: @escaping @MainActor ([ShipPlacement], DeployHandoff) async throws -> Void
    ) async {
        async let outcome: Void = request(fleet, handoff)
        deploy = .locking
        try? await Task.sleep(for: .seconds(beat(Timing.deployCastOff)))
        deploy = .departing
        try? await Task.sleep(for: .seconds(beat(Timing.deployCastOff)))
        handoff.open()
        do {
            try await outcome
            AccessibilityNotification.Announcement("Fleet deployed. Starting battle.").post()
        } catch {
            app.feedback.play(.toastError)
            ToastCenter.shared.show(.error, error.userMessage)
        }
        // Back to the berths: unseen once the next screen has taken over, and right when it hasn't.
        deploy = .returning
        try? await Task.sleep(for: .seconds(beat(Timing.deployCastOff * 2)))
        deploy = .idle
    }

    /// A cast-off beat under the policy: as written at full speed, shorter in the reduced tier, and
    /// `Timing.deployReduced` when sequences collapse (brackets fade in, ships fade out together).
    private func beat(_ full: TimeInterval) -> TimeInterval {
        policy.collapsesSequences || policy.holdsStill ? Timing.deployReduced : policy.duration(full)
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
