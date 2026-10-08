import BattleshipAPI
import BattleshipCore
import SwiftUI

/// Every battle in one place: challenges to answer, games where it's your move, games waiting on
/// someone else, and recent results.
struct LobbyView: View {
    private struct NewGameRequest: Identifiable {
        let id = UUID()
        var draft: NewGameDraft
    }

    private enum PendingRemoval: Identifiable {
        case resign(LobbyEntry)

        var id: UUID {
            switch self {
            case let .resign(entry): entry.id
            }
        }
    }

    @Environment(AppModel.self) private var app
    @State private var path: [GameRoute] = []
    @State private var newGame: NewGameRequest?
    @State private var showsSignIn = false
    @State private var pendingRemoval: PendingRemoval?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    LobbyHero(isSignedIn: app.isSignedIn, rating: app.session.account?.stats.rating) {
                        newGame = NewGameRequest(draft: NewGameDraft())
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                if !app.isSignedIn {
                    Section {
                        SignInPrompt { showsSignIn = true }
                    }
                    .listRowBackground(Theme.rowBackground)
                } else if let error = app.online.refreshError {
                    Section {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Theme.rowBackground)
                }

                ForEach(groups) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            NavigationLink(value: entry.route) {
                                GameRow(entry: entry)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                swipeActions(for: entry)
                            }
                        }
                    } header: {
                        LobbySectionHeader(section: group.section, count: group.entries.count)
                    }
                    .listRowBackground(Theme.rowBackground)
                }

                if groups.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No Battles Yet", systemImage: "water.waves")
                        } description: {
                            Text("Start one against the computer, or challenge a friend online.")
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { OceanBackdrop() }
            .navigationTitle("Battleships")
            .navigationDestination(for: GameRoute.self) { route in
                BattleView(route: route, app: app)
            }
            .refreshable {
                await app.online.refresh()
            }
            .toolbar {
                if app.isSignedIn {
                    ToolbarItem(placement: .topBarLeading) {
                        ConnectionBadge(connection: app.online.connection)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newGame = NewGameRequest(draft: NewGameDraft())
                    } label: {
                        Label("New Battle", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $newGame) { request in
                NewGameSheet(draft: request.draft) { route in
                    newGame = nil
                    path = [route]
                }
            }
            .sheet(isPresented: $showsSignIn) {
                AuthSheet()
            }
            .confirmationDialog(
                "Resign this battle?",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { removal in
                Button("Resign", role: .destructive) {
                    if case let .resign(entry) = removal {
                        perform(.resign, on: entry)
                    }
                }
            } message: { _ in
                Text("Your opponent will be awarded the win.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: app.pendingRoute, initial: true) {
                guard let route = app.pendingRoute else { return }
                app.pendingRoute = nil
                newGame = nil
                path = [route]
            }
            .onChange(of: app.newGameRequest, initial: true) {
                guard let draft = app.newGameRequest else { return }
                app.newGameRequest = nil
                path = []
                newGame = NewGameRequest(draft: draft)
            }
        }
    }

    private var groups: [LobbyGroup] {
        Lobby.groups(online: app.isSignedIn ? app.online.summaries : [], solo: app.solo.matches)
    }

    // MARK: Swipe actions

    private enum Action {
        case resign, cancel, decline, delete
    }

    @ViewBuilder
    private func swipeActions(for entry: LobbyEntry) -> some View {
        switch entry {
        case let .online(game):
            switch game.status {
            case .invited where game.isIncomingChallenge:
                Button("Decline", systemImage: "xmark", role: .destructive) { perform(.decline, on: entry) }
            case .invited, .matchmaking:
                Button("Cancel", systemImage: "xmark", role: .destructive) { perform(.cancel, on: entry) }
            case .active:
                Button("Resign", systemImage: "flag.fill") { pendingRemoval = .resign(entry) }
                    .tint(.red)
            case .finished:
                EmptyView()
            }
        case let .solo(match):
            if match.isOver {
                Button("Delete", systemImage: "trash", role: .destructive) { perform(.delete, on: entry) }
            } else {
                Button("Resign", systemImage: "flag.fill") { pendingRemoval = .resign(entry) }
                    .tint(.red)
            }
        }
    }

    private func perform(_ action: Action, on entry: LobbyEntry) {
        Task {
            do {
                switch (action, entry) {
                case let (.decline, .online(game)):
                    try await app.online.decline(game.id)
                case let (.cancel, .online(game)):
                    try await app.online.cancel(game.id)
                case let (.resign, .online(game)):
                    try await app.online.resign(game.id)
                case let (.resign, .solo(match)):
                    var resigned = match
                    try resigned.resign()
                    app.solo.update(resigned)
                case let (.delete, .solo(match)):
                    app.solo.delete(match.id)
                default:
                    break
                }
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}

/// The banner at the top of the lobby: a radar sweeping the sea, a warship on the swell and the
/// big button.
private struct LobbyHero: View {
    let isSignedIn: Bool
    let rating: Int?
    let onNewBattle: @MainActor () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("COMMAND YOUR FLEET")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(Theme.reticle)
                if let rating {
                    Label("\(rating)", systemImage: "star.fill")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.gold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.gold.opacity(0.15), in: Capsule())
                        .accessibilityLabel("Rating \(rating)")
                }
            }
            Text("Ready for\nbattle, Captain?")
                .font(.display(27, weight: .black))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(isSignedIn
                ? "Challenge friends, get matched online, or practise against the computer."
                : "Practise against the computer, or sign in to battle other players.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: 250, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button { onNewBattle() } label: {
                Label("New Battle", systemImage: "scope")
            }
            .buttonStyle(FireButtonStyle(isArmed: true))
            .padding(.top, 8)
            Spacer(minLength: 64)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .background {
            ZStack(alignment: .topTrailing) {
                OceanBackdrop(extendsIntoSafeArea: false)
                RadarScope()
                    .frame(width: 230, height: 230)
                    .offset(x: 70, y: -40)
                    .opacity(0.85)
                HorizonScene(shipPosition: 0.68, shipWidth: 128)
                    .frame(height: 84)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.3), Theme.reticle.opacity(0.2), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
        }
        .shadow(color: Theme.reticle.opacity(0.15), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
    }
}

private struct LobbySectionHeader: View {
    let section: LobbySection
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(section.title.uppercased())
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(color)
            if section == .challenges || section == .yourTurn {
                Text("\(count)")
                    .font(.caption2.weight(.heavy).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(color, in: Capsule())
                    .accessibilityHidden(true)
            }
        }
    }

    private var color: Color {
        switch section {
        case .challenges: Theme.amber
        case .yourTurn: Theme.reticle
        case .waiting, .finished: .white.opacity(0.6)
        }
    }
}

private struct SignInPrompt: View {
    let onSignIn: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.title2)
                .foregroundStyle(Theme.reticle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Play online")
                    .font(.headline)
                Text("Sign in to challenge friends and climb the leaderboard.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Sign In") { onSignIn() }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

/// One game in the lobby.
struct GameRow: View {
    let entry: LobbyEntry

    var body: some View {
        HStack(spacing: 12) {
            OpponentAvatar(name: entry.opponentName, isComputer: isComputer)
                .overlay {
                    Circle()
                        .strokeBorder(ringColor, lineWidth: 2)
                        .padding(-3)
                }
                .padding(3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.opponentName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(entry.updatedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                HStack(spacing: 6) {
                    Text(entry.status)
                        .font(.subheadline.weight(isActionable ? .semibold : .regular))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ModeBadge(mode: entry.mode)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var isComputer: Bool {
        if case .solo = entry { return true }
        return false
    }

    private var isActionable: Bool {
        entry.section == .challenges || entry.section == .yourTurn
    }

    private var statusColor: Color {
        switch entry.section {
        case .challenges: Theme.amber
        case .yourTurn: Theme.reticle
        case .waiting: .secondary
        case .finished: entry.didWin == true ? Theme.victory : .secondary
        }
    }

    private var ringColor: Color {
        switch entry.section {
        case .challenges: Theme.amber
        case .yourTurn: Theme.reticle
        case .waiting: .white.opacity(0.15)
        case .finished: entry.didWin == true ? Theme.victory.opacity(0.6) : .white.opacity(0.15)
        }
    }
}
