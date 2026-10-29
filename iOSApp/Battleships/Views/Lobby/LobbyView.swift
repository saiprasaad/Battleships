import BattleshipAPI
import BattleshipCore
import SwiftUI

/// Every battle in one place: challenges to answer, games where it's your move, games waiting on
/// someone else, and recent results. Sheets rise as glass over this same sea (the host dims and its
/// drift pauses while one is up), rows fan in under the hero and a game that has just become the
/// player's move climbs into Your Move with a sheen. A rematch deploys its fleet on this stack's own
/// path, in place, with no sheet in between.
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
    @Environment(\.motionPolicy) private var policy
    @State private var path: [GameRoute] = []
    @State private var newGame: NewGameRequest?
    /// A rematch's fleet deployment, pushed straight onto this stack.
    @State private var deploy: NewGameDraft?
    @State private var showsSignIn = false
    @State private var pendingRemoval: PendingRemoval?
    @State private var moderation: ModerationRequest?
    /// Restarted after a refresh, so the rows fan in again.
    @State private var rowEntrance = EntranceClock()
    /// Bumped per game as it becomes the player's move: its row plays a sheen.
    @State private var sheens: [UUID: Int] = [:]
    /// Whether live updates dropped since they were last up, for the "Back online" toast.
    @State private var wasOffline = false
    /// Set while the hero button's recoil is being seen before the sheet slides up.
    @State private var isHandingOff = false

    /// Covered by a sheet: the list dims and its sea holds still.
    private var isCovered: Bool { newGame != nil || showsSignIn }

    var body: some View {
        NavigationStack(path: $path) {
            navigatedList
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
            .playerModeration($moderation)
            .onAppear { app.setAmbientScene(.lobby) }
            .onChange(of: app.pendingRoute, initial: true) {
                guard let route = app.pendingRoute else { return }
                app.pendingRoute = nil
                newGame = nil
                deploy = nil
                path = [route]
            }
            .onChange(of: app.newGameRequest, initial: true) {
                handleNewGameRequest()
            }
            .onChange(of: path) { before, after in
                if after.count > before.count {
                    app.feedback.play(.navigate)
                }
            }
            .onChange(of: isCovered) {
                app.feedback.play(.navigate)
            }
            .onChange(of: groups) { before, after in
                noteArrivals(from: before, to: after)
            }
            .onChange(of: app.online.refreshError) { _, error in
                guard let error else { return }
                ToastCenter.shared.show(.error, error)
                app.feedback.play(.toastError)
            }
            .onChange(of: app.online.connection) { before, after in
                if after == .offline, before == .live {
                    wasOffline = true
                } else if after == .live, wasOffline {
                    wasOffline = false
                    ToastCenter.shared.show(.success, "Back online")
                    app.feedback.play(.toastSuccess)
                }
            }
            .task(id: app.session.ratingDelta) {
                // The hero shows the change for a while, then the pill settles on the new rating.
                guard app.session.ratingDelta != nil else { return }
                try? await Task.sleep(for: .seconds(LobbyBeat.deltaHold))
                guard !Task.isCancelled else { return }
                app.session.clearRatingDelta()
            }
        }
    }

    /// The list and its sea. Its chrome and the sheets are separate declarations because one
    /// chain of modifiers is more than the type checker takes in reasonable time.
    private var lobbyList: some View {
        List {
            heroSection
            noticeSection
            gameSections
            if groups.isEmpty {
                Section {
                    emptyState
                        .animation(Motion.Curve.phase.policy(policy), value: isLoadingOnlineGames)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background { OceanBackdrop(isAnimated: !isCovered) }
        .animation(Motion.Curve.list.policy(policy), value: groups)
        // The host dims a fifth while a sheet is up, so the glass reads as glass.
        .overlay {
            Color.black
                .opacity(isCovered ? 0.2 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .animation(Motion.Curve.fade.policy(policy), value: isCovered)
    }

    private var navigatedList: some View {
        lobbyList
            .navigationTitle("Battleships")
            .navigationDestination(for: GameRoute.self) { route in
                BattleView(route: route, app: app)
            }
            // A rematch: Deploy Your Fleet pushed in place, with the "vs …" chip over its board. An
            // error thrown here sails the ships back and shows the deploy screen's own toast.
            .navigationDestination(item: $deploy) { draft in
                FleetPlacementView(
                    mode: draft.mode,
                    confirmTitle: NewGameSheet.confirmTitle(for: draft),
                    opponentDisplayName: draft.opponentDisplayName
                ) { fleet in
                    try await startRematch(draft, fleet: fleet)
                }
            }
            .refreshable {
                await app.online.refresh()
                // The rows fan in again; on the main actor whatever context the refresh runs in.
                await MainActor.run { rowEntrance.restart() }
            }
            .toolbar {
                if app.isSignedIn {
                    ToolbarItem(placement: .topBarLeading) {
                        ConnectionBadge(connection: app.online.connection)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentNewBattle(afterHandoff: false)
                    } label: {
                        Label("New Battle", systemImage: "plus")
                    }
                }
            }
    }

    private var heroSection: some View {
        Section {
            LobbyHero(
                isSignedIn: app.isSignedIn,
                rating: app.session.account?.stats.rating,
                ratingDelta: app.session.ratingDelta
            ) {
                presentNewBattle(afterHandoff: true)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    /// The sign-in prompt, or the inline error row of an empty list; otherwise a toast carries the news.
    @ViewBuilder
    private var noticeSection: some View {
        if !app.isSignedIn {
            Section {
                SignInPrompt { showsSignIn = true }
                    .staggeredEntrance(index: 0, trigger: rowEntrance)
            }
            .listRowBackground(Theme.rowBackground)
        } else if groups.isEmpty, let error = app.online.refreshError {
            Section {
                Label(error, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Theme.rowBackground)
        }
    }

    private var gameSections: some View {
        let indices = rowIndices
        return ForEach(groups) { group in
            Section {
                ForEach(group.entries) { entry in
                    gameRow(entry, index: indices[entry.id] ?? Timing.Stagger.maxItems)
                }
            } header: {
                LobbySectionHeader(section: group.section, count: group.entries.count)
            }
            .listRowBackground(Theme.rowBackground)
        }
    }

    private func gameRow(_ entry: LobbyEntry, index: Int) -> some View {
        NavigationLink(value: entry.route) {
            GameRow(entry: entry, sheen: sheens[entry.id] ?? 0)
        }
        .staggeredEntrance(index: index, trigger: rowEntrance)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            swipeActions(for: entry)
        }
        .playerContextMenu(opponent(in: entry), gameID: entry.id, request: $moderation)
    }

    /// The empty list's one row: the sonar loader while the online games load, the empty sea after.
    /// Three small views rather than one expression, which the type checker gave up on.
    @ViewBuilder
    private var emptyState: some View {
        if isLoadingOnlineGames {
            scanningLoader
        } else {
            emptySea
        }
    }

    private var scanningLoader: some View {
        SonarLoader(captions: ["Scanning the horizon…", "Hailing the fleet…"])
            .padding(.vertical, 28)
            .padding(.horizontal, 8)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    private var emptySea: some View {
        let message = "Start one against the computer, or challenge a friend online."
        return EmptySeaView(title: "No Battles Yet", message: message) {
            Button("New Battle") { presentNewBattle(afterHandoff: false) }
                .buttonStyle(SecondaryButtonStyle())
        }
        .transition(.opacity)
    }

    private var groups: [LobbyGroup] {
        Lobby.groups(online: app.isSignedIn ? app.online.summaries : [], solo: app.solo.matches)
    }

    /// Each row's place from the top, for the stagger of the entrance.
    private var rowIndices: [UUID: Int] {
        var indices: [UUID: Int] = [:]
        for (index, entry) in groups.flatMap(\.entries).enumerated() where indices[entry.id] == nil {
            indices[entry.id] = index
        }
        return indices
    }

    /// Until the first list of online games arrives, an empty lobby isn't known to be empty.
    private var isLoadingOnlineGames: Bool {
        app.isSignedIn && !app.online.hasLoaded && app.online.refreshError == nil
    }

    /// The other player in an online game, who can be reported or blocked from its row.
    private func opponent(in entry: LobbyEntry) -> PlayerSummary? {
        guard case let .online(game) = entry else { return nil }
        return game.opponent
    }

    // MARK: New battles and rematches

    /// Opens the New Battle sheet. From the hero's button the kick is seen first: the sheet follows
    /// `LobbyBeat.handoff` later, at once below the full tier.
    private func presentNewBattle(afterHandoff: Bool) {
        guard newGame == nil, !isHandingOff else { return }
        let delay = afterHandoff && policy.tier == .full ? LobbyBeat.handoff : 0
        guard delay > 0 else {
            newGame = NewGameRequest(draft: NewGameDraft())
            return
        }
        isHandingOff = true
        Task {
            try? await Task.sleep(for: .seconds(delay))
            isHandingOff = false
            if newGame == nil {
                newGame = NewGameRequest(draft: NewGameDraft())
            }
        }
    }

    private func handleNewGameRequest() {
        guard let draft = app.newGameRequest else { return }
        app.newGameRequest = nil
        if draft.isRematch {
            // In place: whatever is on the stack is replaced by Deploy Your Fleet behind a single
            // frame, and the deploy screen's own entrance carries the moment.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                newGame = nil
                path = []
                deploy = draft
            }
            if let opponent = draft.opponentDisplayName {
                AccessibilityNotification.Announcement("Rematch against \(opponent). Deploy your fleet.").post()
            }
        } else {
            path = []
            newGame = NewGameRequest(draft: draft)
        }
    }

    /// The rematch's fleet is placed: the game starts and the battle replaces the deploy screen,
    /// again behind a single frame. An error is thrown back to the deploy screen, which keeps the
    /// player there with a toast.
    private func startRematch(_ draft: NewGameDraft, fleet: [ShipPlacement]) async throws {
        let route = try await app.startGame(draft, fleet: fleet)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            deploy = nil
            path = [route]
        }
        if draft.opponent.isOnline {
            await PushPermission.requestIfNeeded(settings: app.settings)
        }
    }

    // MARK: News

    /// Games that have just become the player's move get a sheen and one announcement. The first
    /// load is an entrance, not news, and a game new to the lobby is simply new.
    private func noteArrivals(from before: [LobbyGroup], to after: [LobbyGroup]) {
        guard !before.isEmpty else { return }
        let known = Set(before.flatMap { $0.entries.map(\.id) })
        let wasYourMove = Set(before.first { $0.section == .yourTurn }?.entries.map(\.id) ?? [])
        let yourMove = after.first { $0.section == .yourTurn }?.entries ?? []
        let turned = yourMove.filter { known.contains($0.id) && !wasYourMove.contains($0.id) }
        guard !turned.isEmpty else { return }
        for entry in turned {
            sheens[entry.id, default: 0] += 1
        }
        let news = turned.count == 1 ? "Your move against \(turned[0].opponentName)" : "Your move in \(turned.count) battles"
        AccessibilityNotification.Announcement(news).post()
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
                ToastCenter.shared.show(.error, error.userMessage)
                app.feedback.play(.toastError)
            }
        }
    }
}

/// The lobby's own beats. The hand-off is the spec's `Timing.buttonHandoff`; all three would move to
/// `Timing` once the foundation owner adds them.
private enum LobbyBeat {
    /// How long a button's recoil is seen before the sheet it opens slides up.
    static let handoff: TimeInterval = 0.18
    /// How long a row's sheen takes to sweep across it.
    static let sheen: TimeInterval = 0.6
    /// How long the rating change stays beside the hero's pill.
    static let deltaHold: TimeInterval = 3
}

/// The banner at the top of the lobby: a radar sweeping the sea, a warship on the swell and the
/// big button. Its sea has depth (tilt parallax) and lags the scroll: the sea at 0.6× and the
/// horizon at 0.3× of the list's movement.
private struct LobbyHero: View {
    let isSignedIn: Bool
    let rating: Int?
    let ratingDelta: Int?
    let onNewBattle: @MainActor () -> Void
    @Environment(\.motionPolicy) private var policy
    @State private var presses = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let scrolls = policy.tier == .full
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("COMMAND YOUR FLEET")
                    .tracking(2)
                    .scaledFont(11, weight: .heavy, design: .rounded, relativeTo: .caption2)
                    .foregroundStyle(Theme.reticle)
                if let rating {
                    ratingPill(rating)
                }
            }
            Text("Ready for\nbattle, Captain?")
                .displayFont(27, weight: .black)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(isSignedIn
                ? "Challenge friends, get matched online, or practise against the computer."
                : "Practise against the computer, or sign in to battle other players.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: 250, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                presses += 1
                onNewBattle()
            } label: {
                Label("New Battle", systemImage: "scope")
            }
            .buttonStyle(FireButtonStyle(isArmed: true))
            .recoil(on: presses, kick: 1.06)
            .padding(.top, 8)
            Spacer(minLength: 64)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .background {
            ZStack(alignment: .topTrailing) {
                // Still: the screen's own sea already drifts behind the card. Bled past the card so
                // the lag never shows an edge.
                ParallaxOcean(extendsIntoSafeArea: false, isAnimated: false)
                    .padding(.vertical, -HeroScroll.limit)
                    .visualEffect { content, proxy in
                        content.offset(y: scrolls ? HeroScroll.seaShift(for: proxy.frame(in: .scrollView).minY) : 0)
                    }
                RadarScope()
                    .frame(width: 230, height: 230)
                    .offset(x: 92, y: -62)
                    .opacity(0.85)
                HorizonScene(shipPosition: 0.68, shipWidth: 128, isLively: true, shipVoyages: true)
                    .frame(height: 84)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .visualEffect { content, proxy in
                        content.offset(y: scrolls ? HeroScroll.horizonShift(for: proxy.frame(in: .scrollView).minY) : 0)
                    }
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

    /// The rating, rolling to new values, with the change floating up beside it for a moment and
    /// the pill glowing in the change's colour.
    private func ratingPill(_ rating: Int) -> some View {
        let tint: Color = ratingDelta.map { $0 >= 0 ? Theme.victory : Theme.hit } ?? Theme.gold
        return HStack(spacing: 6) {
            Label {
                Text("\(rating)")
                    .rollingNumber(rating)
            } icon: {
                Image(systemName: "star.fill")
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.gold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.gold.opacity(0.15), in: Capsule())
            .glow(tint.opacity(ratingDelta == nil ? 0 : 0.8), radius: 8)
            if let ratingDelta {
                DeltaChip(delta: ratingDelta, trigger: ratingDelta)
            }
        }
        .animation(Motion.Curve.fade.policy(policy), value: ratingDelta)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ratingLabel(rating))
    }

    private func ratingLabel(_ rating: Int) -> String {
        guard let ratingDelta, ratingDelta != 0 else { return "Rating \(rating)" }
        return ratingDelta > 0 ? "Rating \(rating), up \(ratingDelta)" : "Rating \(rating), down \(-ratingDelta)"
    }
}

/// The hero's scroll parallax. A plain enum, since the visual effect's `@Sendable` closure reads it.
private enum HeroScroll {
    /// How far the sea and horizon may lag the scroll, in points.
    static let limit: CGFloat = 48

    /// The sea moves at 0.6× the scroll: relative to the card, 0.4× the other way, while the card
    /// is scrolling off the top (a positive `minY` is the pull of a refresh, or an unresolved space).
    static func seaShift(for minY: CGFloat) -> CGFloat {
        minY < 0 ? min(-minY * 0.4, limit) : 0
    }

    /// The horizon at 0.3× the scroll.
    static func horizonShift(for minY: CGFloat) -> CGFloat {
        minY < 0 ? min(-minY * 0.7, limit) : 0
    }
}

private struct LobbySectionHeader: View {
    let section: LobbySection
    let count: Int
    /// Bumped as the count grows, for the pill's pulse.
    @State private var growths = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(section.title.uppercased())
                .tracking(1.6)
                .scaledFont(12, weight: .heavy, design: .rounded, relativeTo: .caption)
                .foregroundStyle(color)
            if section == .challenges || section == .yourTurn {
                Text("\(count)")
                    .font(.caption2.weight(.heavy))
                    .rollingNumber(count)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(color, in: Capsule())
                    .pulse(on: growths)
                    .accessibilityHidden(true)
                    .onChange(of: count) { before, after in
                        if after > before {
                            growths += 1
                        }
                    }
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

/// One game in the lobby. When the game has just become the player's move (`sheen` bumped), a
/// reticle-coloured sheen sweeps the row once while the avatar's ring brightens; a result's colour
/// fades in rather than snapping.
struct GameRow: View {
    let entry: LobbyEntry
    var sheen = 0
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        OneShot(trigger: sheen, duration: LobbyBeat.sheen) { progress in
            let lit = progress < 1 ? 1 - progress : 0
            HStack(spacing: 12) {
                OpponentAvatar(name: entry.opponentName, isComputer: isComputer)
                    .overlay {
                        Circle()
                            .strokeBorder(ringColor, lineWidth: 2)
                            .padding(-3)
                            .glow(Theme.reticle.opacity(lit), radius: 6)
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
            .overlay {
                if policy.tier == .full, progress < 1 {
                    RowSheen(progress: progress)
                }
            }
        }
        .animation(Motion.Curve.fade.policy(policy), value: entry.section)
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

/// A soft band of reticle light crossing a row from left to right, never above a quarter opacity.
private struct RowSheen: View {
    /// 0…1 across the row.
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            LinearGradient(colors: [.clear, Theme.reticle.opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: width * 0.45)
                .offset(x: -width * 0.45 + width * 1.45 * CGFloat(progress))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
