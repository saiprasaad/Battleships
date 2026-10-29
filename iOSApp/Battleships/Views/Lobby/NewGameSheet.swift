import BattleshipAPI
import BattleshipCore
import SwiftUI

/// Choose an opponent and rules, then deploy a fleet. Presented as glass over the lobby's own sea,
/// with a still sea of its own inside; its first sections enter one after another. One selection
/// frame slides between the opponent cards, Difficulty is a three-position dial, friend suggestions
/// settle one after another and Next pulses once when the draft completes (LOB-6).
struct NewGameSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.motionPolicy) private var policy
    @State private var draft: NewGameDraft
    @State private var showsPlacement = false
    @State private var showsSignIn = false
    @State private var entrance = EntranceClock()
    private let onStarted: @MainActor (GameRoute) -> Void

    init(draft: NewGameDraft, onStarted: @escaping @MainActor (GameRoute) -> Void) {
        _draft = State(initialValue: draft)
        self.onStarted = onStarted
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // At accessibility sizes the cards stack, so their titles have room.
                    OpponentPicker(selection: $draft.opponent, isStacked: dynamicTypeSize.isAccessibilitySize)
                        .entrance(entrance, step: 0)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    SheetSectionHeader(title: "Opponent")
                } footer: {
                    Text(draft.opponent.subtitle)
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.opacity)
                }

                if draft.opponent.isOnline && !app.isSignedIn {
                    Section {
                        SignInPrompt(message: "Online battles need an account so your opponent can find you.") {
                            showsSignIn = true
                        }
                    }
                    .listRowBackground(Theme.rowBackground)
                }

                if draft.opponent == .friend {
                    Section {
                        FriendSearchField(username: $draft.friendUsername)
                            .entrance(entrance, step: 1)
                    } header: {
                        SheetSectionHeader(title: "Friend's username")
                    }
                    .listRowBackground(Theme.rowBackground)
                }

                if draft.opponent == .computer {
                    Section {
                        DifficultyDial(selection: $draft.difficulty)
                            .entrance(entrance, step: 1)
                            .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                    } header: {
                        SheetSectionHeader(title: "Difficulty")
                    }
                    .listRowBackground(Theme.rowBackground)
                }

                Section {
                    Picker("Rules", selection: $draft.mode) {
                        ForEach(GameMode.allCases) { mode in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.displayName)
                                Text(mode.tagline)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .entrance(entrance, step: 2)
                } header: {
                    SheetSectionHeader(title: "Rules")
                }
                .listRowBackground(Theme.rowBackground)
            }
            .scrollContentBackground(.hidden)
            // Still: the lobby's sea drifts behind the glass; this one just matches it.
            .background { OceanBackdrop(isAnimated: false) }
            .toastHost()
            .navigationTitle("New Battle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") { showsPlacement = true }
                        .disabled(!canContinue)
                        // Once when the draft completes, so the way on is noticed.
                        .pulse(on: canContinue, scale: 1.12)
                }
            }
            .navigationDestination(isPresented: $showsPlacement) {
                FleetPlacementView(mode: draft.mode, confirmTitle: Self.confirmTitle(for: draft)) { fleet in
                    try await start(with: fleet)
                }
            }
            .sheet(isPresented: $showsSignIn) {
                AuthSheet()
            }
            .onChange(of: showsSignIn) {
                app.feedback.play(.navigate)
            }
            .onChange(of: showsPlacement) {
                if showsPlacement {
                    app.feedback.play(.navigate)
                }
            }
        }
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(32)
        .presentationDragIndicator(.visible)
    }

    private var canContinue: Bool {
        draft.isComplete && (!draft.opponent.isOnline || app.isSignedIn)
    }

    /// The deploy screen's confirm button for a draft: what starting it means.
    static func confirmTitle(for draft: NewGameDraft) -> String {
        switch draft.opponent {
        case .computer: "Start Battle"
        case .randomPlayer: "Find Opponent"
        case .friend: "Send Challenge"
        }
    }

    /// Starts the game once the fleet has cast off. An error is thrown back to the deploy screen,
    /// which sails the ships back and shows it as a toast.
    private func start(with fleet: [ShipPlacement]) async throws {
        let route = try await app.startGame(draft, fleet: fleet)
        if draft.opponent == .friend {
            ToastCenter.shared.show(.success, "Challenge sent to \(draft.trimmedFriendUsername)")
            app.feedback.play(.toastSuccess)
        }
        onStarted(route)
        if draft.opponent.isOnline {
            await PushPermission.requestIfNeeded(settings: app.settings)
        }
    }
}

/// The three ways to find an opponent as cards, with one glowing selection frame that slides
/// between them on `Motion.Curve.snap` (LOB-6): the chosen icon bounces, the others settle to 55 %
/// white. Stacked (accessibility sizes), the cards are full-width rows.
struct OpponentPicker: View {
    @Binding var selection: OpponentChoice
    var isStacked = false
    @Environment(\.motionPolicy) private var policy
    @Namespace private var frame

    var body: some View {
        let cards = isStacked ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        cards {
            ForEach(OpponentChoice.allCases) { choice in
                Button {
                    withAnimation(Motion.Curve.snap.policy(policy)) { selection = choice }
                } label: {
                    OpponentCard(choice: choice, isSelected: selection == choice, isStacked: isStacked, frame: frame)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.title)
                .accessibilityHint(choice.subtitle)
                .accessibilityAddTraits(selection == choice ? .isSelected : [])
            }
        }
    }
}

/// Difficulty as a three-position dial (LOB-6): a capsule thumb slides under Cadet, Captain and
/// Admiral, the tagline crossfades, and one to three chevrons light 60 ms apart under the choice
/// (together below the full tier). VoiceOver gets a plain picker.
struct DifficultyDial: View {
    @Binding var selection: Difficulty
    @Environment(\.motionPolicy) private var policy
    @Namespace private var thumb

    private static let chevronStagger: TimeInterval = 0.06

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Difficulty.allCases) { difficulty in
                    position(difficulty)
                }
            }
            .padding(4)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            Text(selection.tagline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .contentTransition(.opacity)
                .animation(Motion.Curve.fade.policy(policy), value: selection)
        }
        .accessibilityRepresentation {
            Picker("Difficulty", selection: $selection) {
                ForEach(Difficulty.allCases) { difficulty in
                    Text(difficulty.displayName).tag(difficulty)
                }
            }
        }
    }

    private func position(_ difficulty: Difficulty) -> some View {
        let isChosen = selection == difficulty
        let rank = (Difficulty.allCases.firstIndex(of: difficulty) ?? 0) + 1
        let staggers = policy.tier == .full
        return Button {
            withAnimation(Motion.Curve.snap.policy(policy)) { selection = difficulty }
        } label: {
            VStack(spacing: 5) {
                Text(difficulty.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isChosen ? Color.white : Color.secondary)
                HStack(spacing: 2) {
                    ForEach(0..<rank, id: \.self) { index in
                        Image(systemName: "chevron.up")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(isChosen ? Theme.reticle : Color.white.opacity(0.35))
                            .animation(Motion.Curve.state.policy(policy).delay(staggers ? Double(index) * Self.chevronStagger : 0), value: isChosen)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background {
                if isChosen {
                    Capsule()
                        .fill(Theme.reticle.opacity(0.18))
                        .overlay(Capsule().strokeBorder(Theme.reticle.opacity(0.6), lineWidth: 1))
                        .matchedGeometryEffect(id: "thumb", in: thumb)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

/// One of the three ways to find an opponent, as a selectable card. Stacked cards are full-width
/// rows with the whole title, which wraps if it must. The selected card carries the shared
/// selection frame, which `frame` lets slide from the card before.
private struct OpponentCard: View {
    let choice: OpponentChoice
    let isSelected: Bool
    var isStacked = false
    let frame: Namespace.ID

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let layout = isStacked ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(spacing: 9))
        layout {
            Image(systemName: choice.systemImage)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(isSelected ? Theme.reticle : Color.white.opacity(0.55))
                .glow(isSelected ? Theme.reticle : .clear, radius: 8)
                .symbolEffect(.bounce, value: isSelected)
                .frame(height: 30)
            if isStacked {
                Text(choice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(choice.shortTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isStacked ? 14 : 18)
        .padding(.horizontal, isStacked ? 16 : 0)
        .background(shape.fill(isSelected ? Theme.reticle.opacity(0.16) : Theme.rowBackground))
        .overlay {
            if isSelected {
                shape.strokeBorder(Theme.reticle.opacity(0.9), lineWidth: 1.5)
                    .shadow(color: Theme.reticle.opacity(0.35), radius: 10)
                    .matchedGeometryEffect(id: "selection", in: frame)
            } else {
                shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }
        }
        .contentShape(shape)
    }
}

/// Section titles in the same lettering as the battle screen.
struct SheetSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .tracking(1.6)
            .scaledFont(12, weight: .heavy, design: .rounded, relativeTo: .caption)
            .foregroundStyle(.white.opacity(0.72))
    }
}

/// A username field that suggests matching players as you type.
private struct FriendSearchField: View {
    @Environment(AppModel.self) private var app
    @Binding var username: String
    @State private var suggestions: [PlayerSummary] = []

    private static let suggestionStagger: TimeInterval = 0.04

    var body: some View {
        Group {
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, player in
                Button {
                    username = player.username
                    suggestions = []
                } label: {
                    HStack {
                        OpponentAvatar(name: player.username, size: 28)
                        Text(player.username)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(player.rating)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("\(player.username), rating \(player.rating)")
                // The suggestions settle one after another, 40 ms apart.
                .staggeredEntrance(index: index, trigger: suggestions.map(\.id), stagger: Self.suggestionStagger)
            }
        }
        .task(id: username) {
            let query = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.count >= 2, app.isSignedIn else {
                suggestions = []
                return
            }
            // Wait for a pause in typing before asking the server.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let players = (try? await app.api.searchPlayers(prefix: query)) ?? []
            guard !Task.isCancelled else { return }
            suggestions = players.filter { $0.username.caseInsensitiveCompare(query) != .orderedSame }
        }
    }
}
