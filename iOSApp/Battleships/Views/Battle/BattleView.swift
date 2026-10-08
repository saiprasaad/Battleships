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

    init(route: GameRoute, app: AppModel) {
        _controller = State(initialValue: BattleController(route: route, app: app))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.battleBackdrop
                .ignoresSafeArea()

            content
                .environment(\.colorScheme, .dark)

            if let announcement = controller.announcement {
                AnnouncementBanner(announcement: announcement)
                    .padding(.top, 8)
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(announcement.id)
                    .environment(\.colorScheme, .dark)
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
        .animation(.spring(duration: 0.4, bounce: 0.2), value: controller.announcement)
        .animation(.easeInOut(duration: 0.35), value: controller.showsOutcome)
        .navigationTitle(controller.opponentName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(red: 0.05, green: 0.17, blue: 0.33), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
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
    }

    // MARK: Phases

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .loading:
            ProgressView()
                .controlSize(.large)
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
                battlefield(perspective)
            }
        }
    }

    private func battlefield(_ perspective: BattlePerspective) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                BattleHeader(
                    perspective: perspective,
                    statusLine: controller.statusLine,
                    isMyTurn: controller.isMyTurn,
                    isWaiting: controller.phase == .battle && !controller.isMyTurn
                )

                if horizontalSizeClass == .regular {
                    HStack(alignment: .top, spacing: 28) {
                        BoardSection(title: "Enemy Waters") { targetBoard(perspective) }
                        BoardSection(title: "Your Fleet") { homeBoard(perspective) }
                    }
                } else {
                    BoardSection(title: "Enemy Waters") { targetBoard(perspective) }
                    BoardSection(title: "Your Fleet") {
                        homeBoard(perspective)
                            .frame(maxWidth: 250)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            bottomBar(perspective)
        }
    }

    private func targetBoard(_ perspective: BattlePerspective) -> some View {
        TargetBoard(
            perspective: perspective,
            aimed: controller.aimed,
            effects: controller.effects,
            isInteractive: controller.isMyTurn,
            onTap: controller.tapTarget
        )
    }

    private func homeBoard(_ perspective: BattlePerspective) -> some View {
        HomeBoard(perspective: perspective, effects: controller.effects)
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

/// A titled board.
private struct BoardSection<Board: View>: View {
    let title: String
    @ViewBuilder let board: () -> Board

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityAddTraits(.isHeader)
            board()
                .frame(maxWidth: .infinity)
        }
    }
}
