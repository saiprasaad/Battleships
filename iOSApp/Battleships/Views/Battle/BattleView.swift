import BattleshipAPI
import BattleshipCore
import SwiftUI

/// One battle, online or against the computer.
struct BattleView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controller: BattleController
    @State private var confirmsResign = false
    @State private var showsAcceptSheet = false
    @State private var showsFleet = false

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
                    celebrates: didWin && !reduceMotion,
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
        .onChange(of: controller.announcement) {
            if let announcement = controller.announcement {
                AccessibilityNotification.Announcement(announcement.message).post()
            }
        }
        .onAppear { app.visibleGameID = controller.gameID }
        .onDisappear {
            if app.visibleGameID == controller.gameID {
                app.visibleGameID = nil
            }
        }
        .alert("Something went wrong", isPresented: errorIsPresented) {
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
                    }
                }
            }
        }
        .sheet(isPresented: $showsFleet) {
            FleetSheet(controller: controller)
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
                mode: controller.mode
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

    /// iPhone: the HUD with a miniature of the player's fleet, and enemy waters filling the width.
    private func compactBattlefield(_ perspective: BattlePerspective) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                hud(perspective, isWide: false)
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
        .safeAreaInset(edge: .bottom) {
            bottomBar(perspective)
        }
    }

    /// iPad: both boards at full size, side by side or one above the other, whichever fits bigger.
    private func wideBattlefield(_ perspective: BattlePerspective) -> some View {
        VStack(spacing: 16) {
            hud(perspective, isWide: true)
                .frame(maxWidth: 1040)
            if controller.canClaimVictory {
                claimVictoryCard
                    .frame(maxWidth: 640)
            }
            GeometryReader { proxy in
                let layout = BoardLayout(available: proxy.size)
                let stack = layout.isStacked
                    ? AnyLayout(VStackLayout(spacing: 18))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 36))
                stack {
                    BoardSection(title: "Enemy Waters", detail: shotsDetail(perspective.myStats)) {
                        targetBoard(perspective)
                    }
                    .frame(width: layout.side)
                    BoardSection(title: "Your Fleet", detail: "\(perspective.enemyStats.hits) hits taken") {
                        HomeBoard(perspective: perspective, effects: controller.effects, isUnderFire: isUnderFire)
                            .shakes(on: controller.hitsTaken)
                    }
                    .frame(width: layout.side)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .safeAreaInset(edge: .bottom) {
            bottomBar(perspective)
                .frame(maxWidth: 680)
        }
    }

    private func hud(_ perspective: BattlePerspective, isWide: Bool) -> some View {
        BattleHUD(
            perspective: perspective,
            headline: controller.headline,
            statusLine: controller.statusLine,
            mood: controller.mood,
            isWide: isWide
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
        ClaimVictoryCard(opponentName: controller.opponentName) {
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
        return "\(stats.shotsFired) shots · \(stats.hits) hits"
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
            if controller.phase == .battle {
                Menu {
                    Button("Resign", systemImage: "flag.fill", role: .destructive) {
                        confirmsResign = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Battle options")
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )
    }

    private func rematch() {
        app.requestRematch(of: controller.route)
        dismiss()
    }
}

/// How big the two boards can be on a wide screen, and whether they sit side by side or stacked.
private struct BoardLayout {
    let side: CGFloat
    let isStacked: Bool

    init(available size: CGSize) {
        let header: CGFloat = 28
        let sideBySide = min((size.width - 36) / 2, size.height - header)
        let stacked = min(size.width, (size.height - 18) / 2 - header)
        isStacked = stacked > sideBySide
        side = max(140, isStacked ? stacked : sideBySide)
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
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.72))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            board()
                .frame(maxWidth: .infinity)
        }
    }
}
