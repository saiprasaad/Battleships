import BattleshipAPI
import BattleshipCore
import SwiftUI

/// One battle, online or against the computer.
struct BattleView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controller: BattleController
    @State private var confirmsResign = false
    @State private var showsAcceptSheet = false
    @State private var showsFleet = false
    @State private var moderation: ModerationRequest?

    init(route: GameRoute, app: AppModel) {
        self.init(controller: BattleController(route: route, app: app))
    }

    init(controller: BattleController) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        ZStack(alignment: .top) {
            OceanBackdrop()
            DamageFlash(trigger: controller.hitsTaken)

            content
                // The game-over card is modal, so VoiceOver mustn't wander onto the board behind it.
                .accessibilityHidden(controller.showsOutcome)

            if let announcement = controller.announcement {
                AnnouncementBanner(announcement: announcement)
                    .padding(.top, 8)
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(announcement.id)
            }

            if controller.showsOutcome, let perspective = controller.perspective, let didWin = perspective.didWin {
                GameOverOverlay(
                    didWin: didWin,
                    reason: perspective.outcome?.reason,
                    opponentName: controller.opponentName,
                    stats: perspective.myStats,
                    celebrates: didWin && !Motion.holdsStill(reduceMotion: reduceMotion),
                    onRematch: rematch,
                    onClose: { controller.showsOutcome = false }
                )
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: controller.announcement)
        .animation(.easeInOut(duration: 0.35), value: controller.showsOutcome)
        .navigationTitle(controller.opponentName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Theme.abyss.opacity(0.4), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { toolbarContent }
        .task { await controller.load() }
        .onChange(of: controller.perspective?.moves.count) { controller.syncMoves() }
        .onChange(of: controller.perspective?.outcome) { controller.syncMoves() }
        .onChange(of: controller.spokenAnnouncement) {
            if let announcement = controller.spokenAnnouncement {
                AccessibilityNotification.Announcement(Self.spoken(announcement)).post()
            }
        }
        .onAppear { controller.viewDidAppear() }
        .onDisappear { controller.viewDidDisappear() }
        .alert("Something went wrong", isPresented: errorIsPresented(overAcceptSheet: false)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .confirmationDialog("Resign this battle?", isPresented: $confirmsResign, titleVisibility: .visible) {
            Button("Resign", role: .destructive) {
                Task { await controller.resign() }
            }
        } message: {
            Text(controller.isSolo ? "The computer takes the win." : "\(controller.opponentName) will be awarded the win.")
        }
        .sheet(isPresented: $showsAcceptSheet) {
            NavigationStack {
                FleetPlacementView(mode: controller.mode ?? .classic, confirmTitle: "Accept") { fleet in
                    if await controller.acceptChallenge(with: fleet) {
                        showsAcceptSheet = false
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showsAcceptSheet = false }
                            .disabled(controller.isSubmitting)
                    }
                }
                .alert("Something went wrong", isPresented: errorIsPresented(overAcceptSheet: true)) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(controller.errorMessage ?? "")
                }
            }
        }
        .sheet(isPresented: $showsFleet) {
            FleetSheet(controller: controller)
        }
        .playerModeration($moderation) { _ in
            // Blocking withdraws a challenge between the two players, which leaves nothing to show.
            if case .unavailable = controller.phase {
                dismiss()
            }
        }
    }

    // MARK: Phases

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .unavailable(reason):
            ContentUnavailableView {
                Label("Battle Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(reason)
            } actions: {
                Button("Back to Battles") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }

        case .waitingForOpponent:
            WaitingCard(
                isMatchmaking: controller.onlineGame?.summary.status == .matchmaking,
                opponentName: controller.opponentName,
                mode: controller.mode,
                isSubmitting: controller.isSubmitting
            ) {
                Task {
                    if await controller.cancelGame() {
                        dismiss()
                    }
                }
            }

        case .challenged:
            ChallengeCard(
                opponentName: controller.opponentName,
                caption: controller.opponentCaption,
                mode: controller.mode,
                isSubmitting: controller.isSubmitting,
                onAccept: { showsAcceptSheet = true },
                onDecline: {
                    Task {
                        if await controller.declineChallenge() {
                            dismiss()
                        }
                    }
                }
            )

        case .battle, .finished:
            if let perspective = controller.perspective {
                if horizontalSizeClass == .regular {
                    wideBattlefield(perspective)
                } else {
                    compactBattlefield(perspective)
                }
            }
        }
    }

    /// iPhone: the HUD with a miniature of the player's fleet, and enemy waters as big as they can be
    /// while the whole board stays in view above the Fire bar. When that would make the board too
    /// small (large text, a short screen), the board takes the full width and the battle scrolls.
    private func compactBattlefield(_ perspective: BattlePerspective) -> some View {
        GeometryReader { proxy in
            let isNarrow = proxy.size.width < 360 || dynamicTypeSize.isAccessibilitySize
            ScrollView {
                // The padding comes out of the height the column has to fit in.
                BattleColumn(fitHeight: proxy.size.height - 18) {
                    hud(perspective, layout: isNarrow ? .narrow : .compact)
                    if controller.canClaimVictory {
                        claimVictoryCard
                    }
                    BoardSection(title: "Enemy Waters", detail: shotsDetail(perspective.myStats)) {
                        targetBoard(perspective)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar(perspective)
        }
    }

    /// iPad: both boards at full size, side by side or one above the other, whichever fits bigger.
    private func wideBattlefield(_ perspective: BattlePerspective) -> some View {
        VStack(spacing: 16) {
            hud(perspective, layout: .wide)
                .frame(maxWidth: 1040)
            if controller.canClaimVictory {
                claimVictoryCard
                    .frame(maxWidth: 640)
            }
            GeometryReader { proxy in
                let layout = BoardLayout(available: proxy.size)
                if layout.fits {
                    boardPair(perspective, layout: layout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    // A window too short for both boards at a playable size: they scroll instead.
                    ScrollView {
                        boardPair(perspective, layout: layout)
                            .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .safeAreaInset(edge: .bottom) {
            bottomBar(perspective)
                .frame(maxWidth: 680)
        }
    }

    private func boardPair(_ perspective: BattlePerspective, layout: BoardLayout) -> some View {
        let stack = layout.isStacked
            ? AnyLayout(VStackLayout(spacing: 18))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 36))
        return stack {
            BoardSection(title: "Enemy Waters", detail: shotsDetail(perspective.myStats)) {
                targetBoard(perspective)
            }
            .frame(width: layout.side)
            BoardSection(title: "Your Fleet", detail: Phrase.count(perspective.enemyStats.hits, "hit") + " taken") {
                HomeBoard(perspective: perspective, effects: controller.effects, isUnderFire: isUnderFire)
                    .shakes(on: controller.hitsTaken)
            }
            .frame(width: layout.side)
        }
    }

    private func hud(_ perspective: BattlePerspective, layout: BattleHUDLayout) -> some View {
        BattleHUD(
            perspective: perspective,
            headline: controller.headline,
            statusLine: controller.statusLine,
            mood: controller.mood,
            layout: layout,
            onShowFleet: { showsFleet = true }
        ) {
            MiniMapButton(
                perspective: perspective,
                effects: controller.effects,
                isUnderFire: isUnderFire,
                hitsTaken: controller.hitsTaken
            ) {
                showsFleet = true
            }
        }
    }

    private var claimVictoryCard: some View {
        ClaimVictoryCard(opponentName: controller.opponentName, isSubmitting: controller.isSubmitting) {
            Task { await controller.claimVictory() }
        }
    }

    private func targetBoard(_ perspective: BattlePerspective) -> some View {
        TargetBoard(
            perspective: perspective,
            aimed: controller.aimed,
            effects: controller.effects,
            isInteractive: controller.isMyTurn,
            onTap: { controller.tapTarget($0) }
        )
        .shakes(on: controller.hitsLanded, amplitude: 4)
    }

    /// The enemy is the one to shoot, so the player's waters are under the gun.
    private var isUnderFire: Bool {
        controller.mood == .danger || controller.mood == .waiting
    }

    private func shotsDetail(_ stats: ShotStats) -> String? {
        guard stats.shotsFired > 0 else { return nil }
        return Phrase.count(stats.shotsFired, "shot") + " · " + Phrase.count(stats.hits, "hit")
    }

    @ViewBuilder
    private func bottomBar(_ perspective: BattlePerspective) -> some View {
        if controller.phase == .battle {
            FireBar(
                aimed: controller.aimed,
                isMyTurn: controller.isMyTurn,
                isSubmitting: controller.isSubmitting,
                canFire: controller.canFire
            ) {
                Task { await controller.fire() }
            }
        } else if controller.phase == .finished, let didWin = perspective.didWin {
            ResultBar(
                didWin: didWin,
                stats: perspective.myStats,
                onSummary: { controller.showsOutcome = true },
                onRematch: rematch
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if showsOptions {
                Menu {
                    if controller.phase == .battle {
                        Button("Resign", systemImage: "flag.fill", role: .destructive) {
                            confirmsResign = true
                        }
                    }
                    if let opponent = controller.opponent {
                        PlayerModerationButtons(
                            player: opponent,
                            gameID: controller.gameID,
                            isBlocked: app.moderation.isBlocked(opponent.id),
                            request: $moderation
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Battle options")
            }
        }
    }

    /// Resigning during a battle, and reporting or blocking an online opponent at any stage.
    private var showsOptions: Bool {
        switch controller.phase {
        case .battle: true
        case .waitingForOpponent, .challenged, .finished: controller.opponent != nil
        case .loading, .unavailable: false
        }
    }

    /// The error alert. While the Accept sheet is up the sheet shows it instead, because this screen
    /// can't present an alert while it's presenting the sheet.
    private func errorIsPresented(overAcceptSheet: Bool) -> Binding<Bool> {
        Binding(
            get: { controller.errorMessage != nil && showsAcceptSheet == overAcceptSheet },
            set: { if !$0 { controller.errorMessage = nil } }
        )
    }

    /// The result of the player's own shot is read at once and never cut short; the opponent's reply
    /// waits until VoiceOver has finished whatever it's saying.
    private static func spoken(_ announcement: BattleController.Announcement) -> AttributedString {
        var message = AttributedString(announcement.message)
        switch announcement.source {
        case .player:
            message.accessibilitySpeechAnnouncementPriority = .high
        case .opponent:
            message.accessibilitySpeechAnnouncementPriority = .low
        case .game:
            break // Default priority.
        }
        return message
    }

    private func rematch() {
        app.requestRematch(of: controller.route)
        dismiss()
    }
}

/// The iPhone battle column: everything above the enemy board at its natural height, then the board
/// (the last view) as big as it can be while the whole column fits in `fitHeight`, so every row is
/// in view without scrolling. If that would leave the board section shorter than
/// `smallestBoardSection`, the board takes the full width instead and the column scrolls.
private struct BattleColumn: Layout {
    let fitHeight: CGFloat
    var spacing: CGFloat = 14
    var smallestBoardSection: CGFloat = 250

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let frames = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.last?.maxY ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard let board = subviews.last else { return [] }
        var frames: [CGRect] = []
        var top: CGFloat = 0
        for subview in subviews.dropLast() {
            let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            frames.append(CGRect(x: 0, y: top, width: width, height: height))
            top += height + spacing
        }
        let room = fitHeight - top
        let boardHeight = room >= smallestBoardSection ? room : nil
        let height = board.sizeThatFits(ProposedViewSize(width: width, height: boardHeight)).height
        frames.append(CGRect(x: 0, y: top, width: width, height: height))
        return frames
    }
}

/// How big the two boards can be on a wide screen, and whether they sit side by side or stacked.
private struct BoardLayout {
    /// Smaller than this, the boards aren't worth playing on, so they scroll at a bigger size instead.
    static let smallestSide: CGFloat = 220

    let side: CGFloat
    let isStacked: Bool
    /// Whether both boards fit in the space at a playable size.
    let fits: Bool

    init(available size: CGSize) {
        let header: CGFloat = 28
        let sideBySide = min((size.width - 36) / 2, size.height - header)
        let stacked = min(size.width, (size.height - 18) / 2 - header)
        let best = max(sideBySide, stacked)
        fits = best >= Self.smallestSide
        if fits {
            isStacked = stacked > sideBySide
            side = best
        } else {
            // Scrolling: side by side if the width allows, as big as the width allows.
            let halfWidth = (size.width - 36) / 2
            isStacked = halfWidth < Self.smallestSide
            side = max(0, min(isStacked ? size.width : halfWidth, 360))
        }
    }
}

/// A titled board.
private struct BoardSection<Board: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let board: () -> Board

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .tracking(1.6)
                    .scaledFont(12, weight: .heavy, design: .rounded, relativeTo: .caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.numericText())
                }
            }
            board()
                .frame(maxWidth: .infinity)
        }
    }
}
