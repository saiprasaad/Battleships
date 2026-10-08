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
                    LobbyHero(isSignedIn: app.isSignedIn) {
                        newGame = NewGameRequest(draft: NewGameDraft())
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                if !app.isSignedIn {
                    Section {
                        SignInPrompt { showsSignIn = true }
                    }
                } else if let error = app.online.refreshError {
                    Section {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(groups) { group in
                    Section(group.section.title) {
                        ForEach(group.entries) { entry in
                            NavigationLink(value: entry.route) {
                                GameRow(entry: entry)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                swipeActions(for: entry)
                            }
                        }
                    }
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

/// The banner at the top of the lobby with the big button.
private struct LobbyHero: View {
    let isSignedIn: Bool
    let onNewBattle: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Command your fleet")
                .font(.title2.weight(.bold))
            Text(isSignedIn
                ? "Challenge friends, get matched online, or practise against the computer."
                : "Practise against the computer, or sign in to battle other players.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
            Button { onNewBattle() } label: {
                Label("New Battle", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 6)
            }
            .primaryActionStyle()
            .tint(Theme.hit)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [Theme.seaTop, Theme.abyss], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "scope")
                    .font(.system(size: 150, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.08))
                    .offset(x: 40, y: -30)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct SignInPrompt: View {
    let onSignIn: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.title2)
                .foregroundStyle(.tint)
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.opponentName)
                        .font(.headline)
                        .lineLimit(1)
                    ModeBadge(mode: entry.mode)
                }
                Text(entry.status)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(entry.updatedAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var isComputer: Bool {
        if case .solo = entry { return true }
        return false
    }

    private var statusColor: Color {
        switch entry.section {
        case .challenges, .yourTurn: .accentColor
        case .waiting: .secondary
        case .finished: entry.didWin == true ? .green : .secondary
        }
    }
}
