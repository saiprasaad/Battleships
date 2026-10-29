import BattleshipAPI
import BattleshipCore
import SwiftUI

/// One battle, online or against the computer.
struct BattleView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.motionPolicy) private var policy
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: BattleController
    @State private var confirmsResign = false
    @State private var showsAcceptSheet = false
    @State private var showsFleet = false
    @State private var moderation: ModerationRequest?
    /// Restarted whenever the battlefield comes on: the HUD, the board and the Fire bar enter in three beats.
    @State private var entrance = EntranceClock()
    /// The banner's toast, made once per announcement so it is drained (and spoken) once.
    @State private var banner: BannerItem?
    /// LAST SHIP or LAST SHIP STANDING in the headline, held for `Timing.calloutHold`.
    @State private var callout: BattleCallout?
    @State private var hasCalledOwnLastShip = false
    /// The HUD's words from the battle, held while the last shell is still in the air (FIN-1).
    @State private var battleLook = BattleLook()
    /// The finale has reached its stamp beat: the headline wipes to the outcome and the ResultBar arrives.
    @State private var finaleStampReached = false
    @State private var outcomePresentation = GameOverPresentation.ceremony
    /// The Summary button asked for the card: a recap, not the ceremony.
    @State private var showsSummaryRecap = false
    @State private var hasHandledOutcome = false
    @State private var outcomeWasShown = false
    @State private var isPersonalBest = false
    @State private var soloStreak: Int?
    /// The battle itself was on screen (not a finished game reopened), so its end is a ceremony.
    @State private var sawBattle = false
    /// The opening is playing and hasn't lit the headline yet.
    @State private var isHeadlineDark = false
    @State private var headlineLights = 0
    @State private var focusRequests = 0
    /// How many times INCOMING has lit, for the status dot's ring.
    @State private var incomings = 0
    @State private var hasAnnouncedCoachMark = false

    init(route: GameRoute, app: AppModel) {
        self.init(controller: BattleController(route: route, app: app))
    }

    init(controller: BattleController) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        observedStage
        .confirmationDialog("Resign this battle?", isPresented: $confirmsResign, titleVisibility: .visible) {
            Button("Resign", role: .destructive) {
                Task { await controller.resign() }
            }
        } message: {
            Text(controller.isSolo ? "The computer takes the win." : "\(controller.opponentName) will be awarded the win.")
        }
        .sheet(isPresented: $showsAcceptSheet) {
            acceptSheet
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

    /// The battlefield, its banner and the game-over card, with the navigation chrome. The observers,
    /// the dialog and the sheets are separate declarations: as one chain, the body was more than
    /// the type checker takes in reasonable time.
    private var stage: some View {
        ZStack(alignment: .top) {
            // Still under a sheet: the glass over it is the only thing that moves (LOB-1).
            OceanBackdrop(isAnimated: !isCovered)
            DamageFlash(trigger: controller.hitsTaken, holdsRed: controller.finale?.didWin == false)

            content
                .overlayPreferenceValue(BattleAnchors.self) { anchors in
                    battleOverlays(anchors)
                }
                .motionIdle(controller.isIdle)
                // The game-over card is modal, so VoiceOver mustn't wander onto the board behind it.
                .accessibilityHidden(controller.showsOutcome)

            if let banner {
                BattleBanner(toast: banner.toast, isGoodNews: banner.isGoodNews, streak: banner.streak)
                    .padding(.top, 8)
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(banner.id)
            }

            if controller.showsOutcome, let perspective = controller.perspective, let didWin = perspective.didWin {
                GameOverOverlay(
                    summary: gameOverSummary(perspective, didWin: didWin),
                    presentation: outcomePresentation,
                    onRematch: rematch,
                    onClose: { controller.showsOutcome = false }
                )
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(Motion.Curve.toast.policy(policy), value: banner?.id)
        .animation(Motion.Curve.fade.policy(policy), value: controller.showsOutcome)
        .navigationTitle(controller.opponentName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Theme.abyss.opacity(0.4), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { toolbarContent }
    }

    /// The stage watching the controller: moves, news, outcome, mood and the fleet's state.
    private var controllerObservedStage: some View {
        stage
            .task { await controller.load() }
            .onChange(of: controller.perspective?.moves.count) { controller.syncMoves() }
            .onChange(of: controller.perspective?.outcome) { controller.syncMoves() }
            .onChange(of: controller.spokenAnnouncement) { speak() }
            .onChange(of: controller.announcement) { updateBanner() }
            .onChange(of: controller.errorMessage) { showError() }
            .onChange(of: controller.showsOutcome) { outcomeDidChange() }
            .onChange(of: controller.opening) { openingDidChange() }
            .onChange(of: controller.mood) { moodDidChange() }
    }

    /// The headline, the last ship, hits taken and aiming, in a chain of their own.
    private var fleetObservedStage: some View {
        controllerObservedStage
            .onChange(of: controller.headline, initial: true) { rememberBattleLook() }
            .onChange(of: controller.statusLine, initial: true) { rememberBattleLook() }
            .onChange(of: controller.isEnemyOnLastShip) {
                if controller.isEnemyOnLastShip, controller.phase == .battle {
                    show(.lastShip(isMine: false))
                }
            }
            .onChange(of: controller.hitsTaken) { noteOwnFleet() }
            .onChange(of: controller.aimed) {
                if controller.aimed != nil {
                    app.settings.hasSeenAimCoachMark = true
                }
            }
            .onChange(of: showsCoachMark) { announceCoachMark() }
    }

    /// The screen's own state: phases, the scene, covers, the fleet sheet, the policy, and appearing.
    private var observedStage: some View {
        fleetObservedStage
        .onChange(of: phaseKey, initial: true) { noteBattlefield() }
        .onChange(of: phaseKey) {
            if phaseKey == .battlefield {
                entrance.restart()
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                controller.skipSequences()
            }
        }
        .onChange(of: isCovered) {
            if isCovered {
                controller.skipSequences()
            }
        }
        .onChange(of: showsFleet) { app.feedback.play(.navigate) }
        .onChange(of: policy.collapsesSequences, initial: true) {
            controller.prefersReducedFinale = policy.collapsesSequences
        }
        .task(id: callout) { await holdCallout() }
        .task(id: controller.finale?.start) { await waitForStamp() }
        .onAppear {
            controller.viewDidAppear()
            app.setAmbientScene(.battle(controller.mood))
        }
        .onDisappear { controller.viewDidDisappear() }
    }

    // MARK: Phases

    /// Which content is on: the battle and its end share the battlefield, so the end never cuts.
    private enum PhaseKey: Hashable {
        case loading, unavailable, waiting, challenged, battlefield
    }

    private var phaseKey: PhaseKey {
        switch controller.phase {
        case .loading: .loading
        case .unavailable: .unavailable
        case .waitingForOpponent: .waiting
        case .challenged: .challenged
        case .battle, .finished: .battlefield
        }
    }

    /// Cards rise from the bottom and settle; below the full tier they fade.
    private var cardTransition: AnyTransition {
        policy.tier == .full
            ? .scale(scale: 0.92).combined(with: .move(edge: .bottom)).combined(with: .opacity)
            : .opacity
    }

    private var content: some View {
        ZStack {
            switch controller.phase {
            case .loading:
                SonarLoader(captions: ["Raising the fleet…", "Charting enemy waters…"])
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 360)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)

            case let .unavailable(reason):
                UnavailableCard(reason: reason) { dismiss() }
                    .transition(.opacity)

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
                .transition(cardTransition)

            case .challenged:
                ChallengeCard(
                    opponentName: controller.opponentName,
                    caption: controller.opponentCaption,
                    mode: controller.mode,
                    isSubmitting: controller.isSubmitting,
                    gameID: controller.gameID,
                    onAccept: { showsAcceptSheet = true },
                    onDecline: {
                        Task {
                            if await controller.declineChallenge() {
                                dismiss()
                            }
                        }
                    }
                )
                .transition(cardTransition)

            case .battle, .finished:
                if let perspective = controller.perspective {
                    battlefield(perspective)
                        .transition(.opacity)
                }
            }
        }
        .animation(Motion.Curve.phase.policy(policy), value: phaseKey)
        .overlay { interruptions }
        .animation(Motion.Curve.fade.policy(policy), value: controller.isCatchingUp)
        // Any touch says the player is here (BAT-14).
        .simultaneousGesture(TapGesture().onEnded { controller.noteInteraction() })
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { _ in controller.noteInteraction() })
    }

    /// Both layouts, with the keyboard: arrow keys move the aim, Return fires (BAT-16).
    private func battlefield(_ perspective: BattlePerspective) -> some View {
        Group {
            if horizontalSizeClass == .regular {
                wideBattlefield(perspective)
            } else {
                compactBattlefield(perspective)
            }
        }
        .focusable(true, interactions: .activate)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveAim(rows: -1, columns: 0) }
        .onKeyPress(.downArrow) { moveAim(rows: 1, columns: 0) }
        .onKeyPress(.leftArrow) { moveAim(rows: 0, columns: -1) }
        .onKeyPress(.rightArrow) { moveAim(rows: 0, columns: 1) }
        .onKeyPress(.return) { fireFromKeyboard() }
    }

    /// The catch-up replay's caption and its tap to skip, and the finale's tap to skip. Both close
    /// input on the controller already; the catcher only turns the tap into the skip.
    @ViewBuilder
    private var interruptions: some View {
        if controller.isCatchingUp {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { controller.skipSequences() }
                .overlay(alignment: .bottom) {
                    ReplayCaption()
                        .padding(.bottom, 16)
                }
                .transition(.opacity)
        } else if isFinaleSkippable {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { controller.skipFinale() }
                .accessibilityHidden(true)
        }
    }

    /// The finale is playing and the card hasn't come yet: a tap anywhere brings it.
    private var isFinaleSkippable: Bool {
        controller.finale != nil && !controller.showsOutcome && !outcomeWasShown
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
                        .battleEntrance(entrance, step: 0)
                    if controller.canClaimVictory {
                        claimVictoryCard
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if showsCoachMark {
                        CoachMark()
                            .frame(maxWidth: .infinity)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                    BoardSection(title: "Enemy Waters", counters: shotCounters(perspective)) {
                        targetBoard(perspective)
                    }
                    .battleEntrance(entrance, step: 1)
                }
                .padding(.horizontal)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .animation(Motion.Curve.phase.policy(policy), value: controller.canClaimVictory)
                .animation(Motion.Curve.fade.policy(policy), value: showsCoachMark)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar(perspective)
                .battleEntrance(entrance, step: 2)
        }
    }

    /// iPad: both boards at full size, side by side or one above the other, whichever fits bigger.
    private func wideBattlefield(_ perspective: BattlePerspective) -> some View {
        VStack(spacing: 16) {
            hud(perspective, layout: .wide)
                .frame(maxWidth: 1040)
                .battleEntrance(entrance, step: 0)
            if controller.canClaimVictory {
                claimVictoryCard
                    .frame(maxWidth: 640)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if showsCoachMark {
                CoachMark()
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
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
            .battleEntrance(entrance, step: 1)
        }
        .animation(Motion.Curve.phase.policy(policy), value: controller.canClaimVictory)
        .animation(Motion.Curve.fade.policy(policy), value: showsCoachMark)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .safeAreaInset(edge: .bottom) {
            bottomBar(perspective)
                .frame(maxWidth: 680)
                .battleEntrance(entrance, step: 2)
        }
    }

    private func boardPair(_ perspective: BattlePerspective, layout: BoardLayout) -> some View {
        let stack = layout.isStacked
            ? AnyLayout(VStackLayout(spacing: 18))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 36))
        return stack {
            BoardSection(title: "Enemy Waters", counters: shotCounters(perspective)) {
                targetBoard(perspective)
            }
            .frame(width: layout.side)
            BoardSection(title: "Your Fleet", counters: [BoardCounter(value: landedHitsTaken(perspective), noun: "hit", suffix: " taken")]) {
                HomeBoard(perspective: perspective, controller: controller, isUnderFire: isUnderFire)
                    // The full board is the home surface on iPad: its bezel lights red under INCOMING.
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.hit.opacity(isBracing ? 0.8 : 0), lineWidth: 1.5)
                            .glow(Theme.hit.opacity(isBracing ? 1 : 0), radius: 6)
                            .allowsHitTesting(false)
                    }
                    .animation(Motion.Curve.settle.policy(policy), value: isBracing)
                    .battleAnchor(.homeSurface)
                    .shakes(on: controller.hitsTaken)
            }
            .frame(width: layout.side)
        }
    }

    private func hud(_ perspective: BattlePerspective, layout: BattleHUDLayout) -> some View {
        BattleHUD(
            perspective: perspective,
            headline: displayedHeadline,
            statusLine: displayedStatusLine,
            mood: displayedMood,
            layout: layout,
            cues: hudCues,
            onShowFleet: { showsFleet = true }
        ) { surface in
            MiniMapButton(
                perspective: perspective,
                controller: controller,
                isUnderFire: isUnderFire,
                hitsTaken: controller.hitsTaken,
                surface: surface,
                isBracing: isBracing
            ) {
                showsFleet = true
            }
            // The home surface dips while the Fleet sheet is up (LOB-1).
            .scaleEffect(showsFleet ? 0.96 : 1)
            .animation(Motion.Curve.state.policy(policy), value: showsFleet)
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
            controller: controller,
            isInteractive: controller.isMyTurn,
            onTap: { controller.tapTarget($0) }
        )
        // The opening's gate: the one visual that closes input, and a tap on it skips the opening.
        .allowsHitTesting(controller.opening == nil)
        .shakes(on: controller.hitsLanded, amplitude: 4)
    }

    @ViewBuilder
    private func bottomBar(_ perspective: BattlePerspective) -> some View {
        ZStack {
            if showsResultBar, let didWin = perspective.didWin {
                ResultBar(
                    didWin: didWin,
                    stats: perspective.myStats,
                    onSummary: {
                        showsSummaryRecap = true
                        controller.showsOutcome = true
                    },
                    onRematch: rematch
                )
                .transition(.opacity)
            } else if controller.phase == .battle || isEndPending {
                FireBar(
                    target: fireTarget,
                    state: fireState,
                    canFire: controller.canFire,
                    shotsFired: perspective.myStats.shotsFired,
                    turnStings: controller.turnStings
                ) {
                    Task { await controller.fire() }
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.Curve.phase.policy(policy), value: showsResultBar)
    }

    // MARK: The shell's arc and the opening, over everything

    /// Hosts what is drawn above the battle from its landmarks: W2's `ShellFlightLayer` from the Fire
    /// button to the aimed cell, and the opening over the enemy's waters.
    private func battleOverlays(_ anchors: [BattleAnchor: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            let fireRect = anchors[.fireButton].map { proxy[$0] }
            let boardRect = anchors[.targetBoard].map { proxy[$0] }
            let cells = Self.cellRects(anchors, in: proxy)
            let shells = controller.shells.filter { $0.board == .target }
            ZStack(alignment: .topLeading) {
                if !shells.isEmpty {
                    ShellFlightLayer(shells: shells, clock: controller.targetClock, from: fireRect, to: { cells[$0] })
                        .allowsHitTesting(false)
                }
                if controller.opening != nil {
                    BattleOpening(controller: controller, targetBoard: boardRect, onHeadlineCue: lightHeadline)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(Motion.Curve.dismiss.policy(policy), value: controller.opening != nil)
        }
    }

    /// Every aimed cell's frame, by coordinate, in the overlay's space.
    private static func cellRects(_ anchors: [BattleAnchor: Anchor<CGRect>], in proxy: GeometryProxy) -> [Coordinate: CGRect] {
        var rects: [Coordinate: CGRect] = [:]
        for (key, anchor) in anchors {
            if case let .targetCell(coordinate) = key {
                rects[coordinate] = proxy[anchor]
            }
        }
        return rects
    }

    private func lightHeadline() {
        isHeadlineDark = false
        headlineLights += 1
    }

    // MARK: What the HUD and the bar show

    /// The enemy is the one to shoot, so the player's waters are under the gun.
    private var isUnderFire: Bool {
        controller.mood == .danger || controller.mood == .waiting
    }

    /// INCOMING, or the enemy's shell on its way: the home surface braces (BAT-4).
    private var isBracing: Bool {
        controller.mood == .danger || controller.telegraph != nil
    }

    /// A sheet is over the battle: its sea holds still and its sequences land.
    private var isCovered: Bool {
        showsAcceptSheet || showsFleet
    }

    /// The HUD's words while a landing is pending (FIN-1), and the callouts.
    private struct BattleLook: Equatable {
        var headline = ""
        var statusLine = ""
        var mood = BattleController.Mood.neutral
    }

    /// The engine has decided the game but the last shell hasn't finished its beat: the HUD, the bar
    /// and the headline hold the battle's state until the stamp, so nothing spoils the landing.
    private var isEndPending: Bool {
        guard controller.phase == .finished, !controller.showsOutcome,
              controller.perspective?.outcome?.reason == .fleetDestroyed
        else { return false }
        if controller.finale != nil {
            return !finaleStampReached
        }
        return controller.shells.contains { $0.board == .target && $0.outcome != .misfire } || controller.telegraph != nil
    }

    private var showsResultBar: Bool {
        controller.phase == .finished && !isEndPending
    }

    private var displayedHeadline: String {
        if isEndPending { return battleLook.headline }
        if let callout, controller.phase == .battle { return callout.headline }
        return controller.headline
    }

    private var displayedStatusLine: String {
        if controller.isCatchingUp { return "While you were away…" }
        return isEndPending ? battleLook.statusLine : controller.statusLine
    }

    private var displayedMood: BattleController.Mood {
        isEndPending ? battleLook.mood : controller.mood
    }

    private var hudCues: HUDCues {
        var cues = HUDCues()
        cues.turnStings = controller.turnStings
        cues.hitsTaken = controller.hitsTaken
        cues.idleCueCount = controller.idleCueCount
        cues.dotBursts = controller.turnStings + incomings
        cues.isBracing = isBracing
        cues.isHeadlineDark = isHeadlineDark
        cues.headlineLights = headlineLights
        cues.focusRequests = focusRequests
        if let callout, controller.phase == .battle, !isEndPending {
            cues.headlineTint = callout.tint
            cues.edgeTint = callout.tint
        }
        cues.pendingTargetCells = pendingTargetCells
        cues.pendingHomeCells = pendingHomeCells
        cues.turnClock = turnClock
        cues.connectionNote = connectionNote
        return cues
    }

    /// Cells on the enemy's waters whose shell hasn't landed: the roster and the counters wait for it.
    private var pendingTargetCells: Set<Coordinate> {
        Set(controller.shells.filter { $0.board == .target && $0.outcome != .misfire }.map(\.coordinate))
    }

    /// The cell the enemy's shell is heading for: not a hit until it lands.
    private var pendingHomeCells: Set<Coordinate> {
        controller.telegraph.map { Set([$0.coordinate]) } ?? []
    }

    /// The opponent's clock, once under a day (BAT-14).
    private var turnClock: TurnClock? {
        guard let summary = controller.onlineGame?.summary, summary.isTheirTurn, let deadline = summary.turnDeadline,
              deadline.timeIntervalSinceNow < TurnClock.span
        else { return nil }
        return TurnClock(deadline: deadline)
    }

    /// The live connection, once it has been up: reconnecting, or offline.
    private var connectionNote: String? {
        guard case .online = controller.route, controller.phase == .battle, app.online.hasLoaded else { return nil }
        switch app.online.connection {
        case .live: return nil
        case .connecting: return "Reconnecting…"
        case .offline: return "Offline. Moves will sync when you're back."
        }
    }

    private var fireState: FireState {
        let shells = controller.shells.filter { $0.board == .target }
        if shells.contains(where: { $0.outcome == .misfire }) { return .misfire }
        if controller.isTransmitting { return .transmitting }
        if !shells.isEmpty { return .firing }
        if controller.opening != nil { return .opening }
        return controller.isMyTurn ? .aiming : .standBy
    }

    /// The cell lined up, or the one the shell in the air is heading for.
    private var fireTarget: Coordinate? {
        controller.aimed ?? controller.shells.last { $0.board == .target }?.coordinate
    }

    /// "12 shots · 3 hits", counting only the shells that have landed.
    private func shotCounters(_ perspective: BattlePerspective) -> [BoardCounter] {
        let pending = pendingTargetCells
        let shots = perspective.myShots.filter { !pending.contains($0.target) }
        guard !shots.isEmpty else { return [] }
        return [
            BoardCounter(value: shots.count, noun: "shot"),
            BoardCounter(value: shots.filter(\.result.isHit).count, noun: "hit"),
        ]
    }

    private func landedHitsTaken(_ perspective: BattlePerspective) -> Int {
        let pending = pendingHomeCells
        return perspective.enemyShots.filter { $0.result.isHit && !pending.contains($0.target) }.count
    }

    /// The first battle's hint: on the player's turn in a game with no shots yet, once any opening
    /// has ended (BAT-15).
    private var showsCoachMark: Bool {
        !app.settings.hasSeenAimCoachMark && controller.phase == .battle && controller.isMyTurn
            && controller.opening == nil && controller.aimed == nil && !controller.isCatchingUp
            && controller.perspective?.myShots.isEmpty == true
    }

    // MARK: Reacting

    private func rememberBattleLook() {
        guard controller.phase == .battle else { return }
        battleLook = BattleLook(headline: controller.headline, statusLine: controller.statusLine, mood: controller.mood)
    }

    private func moodDidChange() {
        app.setAmbientScene(.battle(controller.mood))
        if controller.mood == .danger {
            incomings += 1
        }
        rememberBattleLook()
    }

    private func noteBattlefield() {
        guard phaseKey == .battlefield else { return }
        if controller.phase == .battle {
            sawBattle = true
        }
        if controller.perspective?.myShipsRemaining == 1 {
            // Already down to the last ship: nothing new to call out.
            hasCalledOwnLastShip = true
        }
        // VoiceOver starts on the headline the frame the battle appears.
        focusRequests += 1
    }

    private func openingDidChange() {
        switch controller.opening {
        case .matchFound?, .playing?:
            if policy.collapsesSequences {
                // Collapsed: one announcement, every control available at once.
                AccessibilityNotification.Announcement(BattleOpening.announcement(for: controller, app: app)).post()
                controller.skipOpening()
            } else if case .playing? = controller.opening {
                isHeadlineDark = true
            }
        case nil:
            if isHeadlineDark {
                lightHeadline()
            }
        }
    }

    private func show(_ newCallout: BattleCallout) {
        callout = newCallout
        AccessibilityNotification.Announcement(newCallout.announcement).post()
    }

    private func holdCallout() async {
        guard callout != nil else { return }
        try? await Task.sleep(for: .seconds(Timing.calloutHold))
        guard !Task.isCancelled else { return }
        callout = nil
    }

    /// The enemy's landing left the player one ship: LAST SHIP STANDING, once.
    private func noteOwnFleet() {
        guard controller.phase == .battle, !hasCalledOwnLastShip, controller.perspective?.myShipsRemaining == 1 else { return }
        hasCalledOwnLastShip = true
        show(.lastShip(isMine: true))
        app.feedback.play(.lastShip, variation: FeedbackVariation(isMine: true))
    }

    /// The headline wipes to the outcome at the finale's stamp beat, `Timing.sunkStamp` after the last landing.
    private func waitForStamp() async {
        guard let start = controller.finale?.start else {
            finaleStampReached = false
            return
        }
        let wait = start.addingTimeInterval(Timing.sunkStamp).timeIntervalSinceNow
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
        }
        guard !Task.isCancelled else { return }
        finaleStampReached = true
    }

    private func announceCoachMark() {
        guard showsCoachMark, !hasAnnouncedCoachMark else { return }
        hasAnnouncedCoachMark = true
        AccessibilityNotification.Announcement(CoachMark.defaultText).post()
    }

    // MARK: The banner and the toasts

    /// One announcement's banner: its toast, made once so it is drained and spoken once.
    private struct BannerItem: Identifiable, Equatable {
        let id: UUID
        let toast: Toast
        let isGoodNews: Bool
        let streak: Int

        static func == (lhs: BannerItem, rhs: BannerItem) -> Bool {
            lhs.id == rhs.id
        }
    }

    private func updateBanner() {
        guard let announcement = controller.announcement else {
            banner = nil
            return
        }
        guard banner?.id != announcement.id else { return }
        let streak = announcement.source == .player && announcement.isGoodNews ? controller.hitStreak : 0
        let isLarge = dynamicTypeSize.isAccessibilitySize
        var message = announcement.message
        if streak >= 2, isLarge {
            // No room for the chip beside the text: it reads inline.
            message += " · ×\(streak)"
        }
        let toast = Toast(
            kind: announcement.isGoodNews ? .success : .warning,
            message: message,
            action: nil,
            duration: .seconds(Timing.bannerHold)
        )
        banner = BannerItem(id: announcement.id, toast: toast, isGoodNews: announcement.isGoodNews, streak: isLarge ? 0 : streak)
    }

    /// The result of the player's own shot is read at once and never cut short; the opponent's reply
    /// waits until VoiceOver has finished whatever it's saying. The banner's toast stays silent
    /// (`isSpoken: false`), so every piece of news is posted here, once, with its priority.
    private func speak() {
        guard let announcement = controller.spokenAnnouncement else { return }
        AccessibilityNotification.Announcement(Self.spoken(announcement)).post()
    }

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

    /// Failures are toasts, never alerts (APP-2): a fire that didn't go through offers Retry, which
    /// re-aims the same cell and fires again.
    private func showError() {
        guard let message = controller.errorMessage else { return }
        controller.errorMessage = nil
        let misfired = controller.shells.first { $0.board == .target && $0.outcome == .misfire }?.coordinate
        let retry = misfired.map { target in
            Toast.Action(title: "Retry") {
                controller.aimed = target
                Task { await controller.fire() }
            }
        }
        ToastCenter.shared.show(.error, message, action: retry)
        if misfired == nil {
            // A misfire already buzzed.
            app.feedback.play(.toastError)
        }
    }

    // MARK: The end of the game

    private func outcomeDidChange() {
        guard controller.showsOutcome else { return }
        outcomeWasShown = true
        let isRecapRequest = showsSummaryRecap
        showsSummaryRecap = false
        outcomePresentation = isRecapRequest || !sawBattle ? .recap : .ceremony
        guard !isRecapRequest, !hasHandledOutcome, let didWin = controller.perspective?.didWin else { return }
        hasHandledOutcome = true
        if controller.isSolo {
            // The winning run against the computer, once per outcome.
            app.settings.soloWinStreak = didWin ? app.settings.soloWinStreak + 1 : 0
            soloStreak = app.settings.soloWinStreak
        } else {
            Task {
                await app.session.refreshAccount()
                if let rating = app.session.account?.stats.rating {
                    isPersonalBest = app.settings.noteRating(rating)
                }
            }
        }
    }

    private func gameOverSummary(_ perspective: BattlePerspective, didWin: Bool) -> GameOverSummary {
        let isOnline = !controller.isSolo
        return GameOverSummary(
            didWin: didWin,
            reason: perspective.outcome?.reason,
            opponentName: controller.opponentName,
            stats: perspective.myStats,
            ratingBefore: isOnline ? (app.session.previousRating ?? app.session.account?.stats.rating) : nil,
            ratingDelta: isOnline ? app.session.ratingDelta : nil,
            isPersonalBest: isPersonalBest,
            soloStreak: soloStreak,
            finalBoard: perspective
        )
    }

    /// In place (OPN-3): the lobby replaces its path with Deploy Your Fleet behind one frame, so the
    /// recoil is seen first and nothing here is dismissed.
    private func rematch() {
        let delay = policy.tier == .full ? BattleBeat.handoff : 0
        Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            app.requestRematch(of: controller.route)
        }
    }

    // MARK: The keyboard

    /// Arrow keys move the aim across the enemy's waters, stepping over cells already fired at.
    private func moveAim(rows: Int, columns: Int) -> KeyPress.Result {
        guard controller.isMyTurn, let perspective = controller.perspective else { return .ignored }
        var next: Coordinate
        if let aimed = controller.aimed {
            next = aimed.offsetBy(rows: rows, columns: columns)
        } else if let last = controller.latestOwnShot {
            next = last.offsetBy(rows: rows, columns: columns)
        } else {
            next = Coordinate(row: 0, column: 0)
        }
        while perspective.rules.contains(next), !perspective.canTarget(next) {
            next = next.offsetBy(rows: rows, columns: columns)
        }
        guard perspective.rules.contains(next) else { return .handled }
        controller.noteInteraction()
        controller.aimed = next
        app.feedback.play(.aim)
        return .handled
    }

    private func fireFromKeyboard() -> KeyPress.Result {
        guard controller.canFire else { return .ignored }
        Task { await controller.fire() }
        return .handled
    }

    // MARK: Sheets and the toolbar

    /// The accept sheet: glass over the battle, with the deploy screen's own toast host. The request
    /// runs while the ships cast off; the sheet goes once both are done, and a failure sails them back.
    private var acceptSheet: some View {
        NavigationStack {
            FleetPlacementView(
                mode: controller.mode ?? .classic,
                confirmTitle: "Accept",
                opponentDisplayName: controller.opponentName
            ) { fleet, handoff in
                let accepted = await controller.acceptChallenge(with: fleet)
                await handoff.departed()
                if accepted {
                    showsAcceptSheet = false
                    return
                }
                let message = controller.errorMessage ?? "Something went wrong. Please try again."
                // The deploy screen's own toast says it.
                controller.errorMessage = nil
                throw AcceptFailure(message: message)
            }
            .stillBackdrop()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showsAcceptSheet = false }
                        .disabled(controller.isSubmitting)
                }
            }
            .toastHost()
        }
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(32)
        .presentationDragIndicator(.visible)
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
}

/// Accepting a challenge failed: the deploy screen sails the ships back and shows this.
private struct AcceptFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private extension View {
    /// The battlefield's three-beat entrance (OPN-1): the HUD drops 24 pt into place, the board
    /// scales 0.94 → 1 a beat later, the Fire bar rises from the bottom edge a beat after that.
    func battleEntrance(_ clock: EntranceClock, step: Int) -> some View {
        let offset: CGFloat = step == 0 ? -24 : (step == 2 ? 24 : 0)
        let scale: CGFloat = step == 1 ? 0.94 : 1
        return staggeredEntrance(index: step, trigger: clock, offset: offset, scale: scale, stagger: Timing.Stagger.block)
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

/// One number in a board section's header: "12 shots", "3 hits taken".
private struct BoardCounter: Hashable {
    let value: Int
    let noun: String
    var suffix = ""
}

/// A titled board, with its counters rolling to their values (APP-3).
private struct BoardSection<Board: View>: View {
    let title: String
    var counters: [BoardCounter] = []
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
                if !counters.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(counters.enumerated()), id: \.offset) { index, counter in
                            if index > 0 {
                                Text(" · ")
                            }
                            Text("\(counter.value)")
                                .rollingNumber(counter.value)
                            Text(" \(counter.noun)\(counter.value == 1 ? "" : "s")\(counter.suffix)")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityElement(children: .combine)
                }
            }
            board()
                .frame(maxWidth: .infinity)
        }
    }
}
