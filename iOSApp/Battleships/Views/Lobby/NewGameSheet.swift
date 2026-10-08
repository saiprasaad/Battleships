import BattleshipAPI
import BattleshipCore
import SwiftUI

/// Choose an opponent and rules, then deploy a fleet.
struct NewGameSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NewGameDraft
    @State private var showsPlacement = false
    @State private var showsSignIn = false
    @State private var errorMessage: String?
    private let onStarted: @MainActor (GameRoute) -> Void

    init(draft: NewGameDraft, onStarted: @escaping @MainActor (GameRoute) -> Void) {
        _draft = State(initialValue: draft)
        self.onStarted = onStarted
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        ForEach(OpponentChoice.allCases) { choice in
                            Button {
                                withAnimation(.snappy) { draft.opponent = choice }
                            } label: {
                                OpponentCard(choice: choice, isSelected: draft.opponent == choice)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.title)
                            .accessibilityHint(choice.subtitle)
                            .accessibilityAddTraits(draft.opponent == choice ? .isSelected : [])
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } header: {
                    SheetSectionHeader(title: "Opponent")
                } footer: {
                    Text(draft.opponent.subtitle)
                        .contentTransition(.opacity)
                }

                if draft.opponent.isOnline && !app.isSignedIn {
                    Section {
                        Button("Sign in to play online") { showsSignIn = true }
                    } footer: {
                        Text("Online battles need an account so your opponent can find you.")
                    }
                    .listRowBackground(Theme.rowBackground)
                }

                if draft.opponent == .friend {
                    Section {
                        FriendSearchField(username: $draft.friendUsername)
                    } header: {
                        SheetSectionHeader(title: "Friend's username")
                    }
                    .listRowBackground(Theme.rowBackground)
                }

                if draft.opponent == .computer {
                    Section {
                        Picker("Difficulty", selection: $draft.difficulty) {
                            ForEach(Difficulty.allCases) { difficulty in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(difficulty.displayName)
                                    Text(difficulty.tagline)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(difficulty)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
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
                } header: {
                    SheetSectionHeader(title: "Rules")
                }
                .listRowBackground(Theme.rowBackground)
            }
            .scrollContentBackground(.hidden)
            .background { OceanBackdrop() }
            .navigationTitle("New Battle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") { showsPlacement = true }
                        .disabled(!canContinue)
                }
            }
            .navigationDestination(isPresented: $showsPlacement) {
                FleetPlacementView(mode: draft.mode, confirmTitle: confirmTitle) { fleet in
                    await start(with: fleet)
                }
            }
            .sheet(isPresented: $showsSignIn) {
                AuthSheet()
            }
            .alert("Couldn't start the battle", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var canContinue: Bool {
        draft.isComplete && (!draft.opponent.isOnline || app.isSignedIn)
    }

    private var confirmTitle: String {
        switch draft.opponent {
        case .computer: "Start Battle"
        case .randomPlayer: "Find Opponent"
        case .friend: "Send Challenge"
        }
    }

    private func start(with fleet: [ShipPlacement]) async {
        do {
            switch draft.opponent {
            case .computer:
                let match = try app.solo.start(mode: draft.mode, difficulty: draft.difficulty, fleet: fleet)
                onStarted(.solo(match.id))
            case .randomPlayer:
                let game = try await app.online.create(CreateGameRequest(mode: draft.mode, fleet: fleet))
                onStarted(.online(game.id))
                await PushPermission.requestIfNeeded(settings: app.settings)
            case .friend:
                let game = try await app.online.create(
                    CreateGameRequest(mode: draft.mode, fleet: fleet, opponent: draft.trimmedFriendUsername)
                )
                onStarted(.online(game.id))
                await PushPermission.requestIfNeeded(settings: app.settings)
            }
        } catch {
            errorMessage = error.userMessage
            app.feedback.play(.invalid)
        }
    }
}

/// One of the three ways to find an opponent, as a selectable card.
private struct OpponentCard: View {
    let choice: OpponentChoice
    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(spacing: 9) {
            Image(systemName: choice.systemImage)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(isSelected ? Theme.reticle : Color.white.opacity(0.55))
                .glow(isSelected ? Theme.reticle : .clear, radius: 8)
                .symbolEffect(.bounce, value: isSelected)
                .frame(height: 30)
            Text(choice.shortTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .white : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(shape.fill(isSelected ? Theme.reticle.opacity(0.16) : Theme.rowBackground))
        .overlay(shape.strokeBorder(isSelected ? Theme.reticle.opacity(0.9) : Color.white.opacity(0.1), lineWidth: isSelected ? 1.5 : 1))
        .shadow(color: isSelected ? Theme.reticle.opacity(0.3) : .clear, radius: 10)
        .contentShape(shape)
    }
}

/// Section titles in the same lettering as the battle screen.
struct SheetSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .tracking(1.6)
            .foregroundStyle(.white.opacity(0.72))
    }
}

/// A username field that suggests matching players as you type.
private struct FriendSearchField: View {
    @Environment(AppModel.self) private var app
    @Binding var username: String
    @State private var suggestions: [PlayerSummary] = []

    var body: some View {
        Group {
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
            ForEach(suggestions) { player in
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
