import BattleshipAPI
import BattleshipClient
import BattleshipCore
import Foundation
import Observation

// MARK: - What the boards draw

/// Which of the two boards something happens on.
enum BoardSide: Sendable {
    case target
    case home
}

/// A shell in the air, from the Fire button to a cell. `lands` is unknown while an online shot waits
/// at the apex for the server's answer. `outcome` is known once the engine has decided the result,
/// and is `.misfire` when the request failed: the shell fizzles for a moment instead of landing.
struct ShellFlight: Identifiable, Equatable, Sendable {
    enum Outcome: Sendable {
        case hit
        case miss
        case sunk
        case misfire
    }

    let id: UUID
    let board: BoardSide
    let coordinate: Coordinate
    let start: Date
    var lands: Date?
    var outcome: Outcome?
}

/// A shell landing on a board, animated where it hit from `start`.
struct Impact: Identifiable, Equatable, Sendable {
    let id: UUID
    let board: BoardSide
    let coordinate: Coordinate
    let isHit: Bool
    let isSunk: Bool
    /// The shot that ended the game.
    let isFinal: Bool
    let start: Date
    /// A miss right beside one of the shooter's earlier hits: a taller column, a sharper splash.
    var isClose = false
}

/// The enemy's shell on its way: the home board shows where it will land, from `start` until `lands`.
struct Telegraph: Equatable, Sendable {
    let coordinate: Coordinate
    let start: Date
    let lands: Date
}

/// A ship going down, animated for `Timing.sinking` from `start` (kept in `sinkings` for `beats.sinking`).
struct Sinking: Identifiable, Equatable, Sendable {
    let id: UUID
    let board: BoardSide
    let ship: ShipPlacement
    let start: Date
}

/// The SUNK stamp slamming onto a ship at `start`, held for `Timing.stampHold`.
struct Stamp: Identifiable, Equatable, Sendable {
    let id: UUID
    let board: BoardSide
    let ship: ShipPlacement
    let start: Date
}

/// The shot that ended the game, from which the board runs its chain detonation and surfacing fleet.
struct Finale: Equatable, Sendable {
    let board: BoardSide
    let coordinate: Coordinate
    let start: Date
    let didWin: Bool
}

/// An `Impact` as the boards drew it before `impacts` existed. Kept until every view reads `impacts`.
struct ImpactEffect: Identifiable, Equatable, Sendable {
    typealias Board = BoardSide

    let id: UUID
    let board: BoardSide
    let coordinate: Coordinate
    let isHit: Bool

    init(_ impact: Impact) {
        id = impact.id
        board = impact.board
        coordinate = impact.coordinate
        isHit = impact.isHit
    }
}

/// How long each beat of the shot loop takes, in seconds. The defaults are the `Timing` tokens; tests
/// set `.instant` so that everything lands at once.
struct Beats: Sendable {
    /// Fire to landing.
    var shellFlight = Timing.shellFlight
    /// Online: how far into the flight the shell waits for the server.
    var apexHold = Timing.apexHold
    /// Online: how long a wait at the apex is before the fire bar says TRANSMITTING.
    var apexTimeout = Timing.apexTimeout
    /// How long an `Impact` stays in `impacts`.
    var impactLinger = Timing.impactLinger
    /// How long a `Sinking` stays in `sinkings`.
    var sinking = Timing.sinking
    /// Landing to the SUNK stamp.
    var sunkStamp = Timing.sunkStamp
    /// How long the stamp stays in `stamps`.
    var stampHold = Timing.stampHold
    /// How long the enemy's shell is telegraphed before it lands.
    var whistle = Timing.whistle
    /// The enemy's landing to the turn sting.
    var turnSting = Timing.turnSting
    /// The last landing to the outcome card.
    var finaleCard = Timing.finaleCard
    /// The same under `prefersReducedFinale`.
    var finaleCardReduced = Timing.finaleCardReduced
    /// Between the opponent's shots in a catch-up replay.
    var catchUpStep = Timing.catchUpStep
    /// The opening of a game with no moves yet.
    var opening = Timing.opening
    /// The Match Found card before the opening, for an online opponent who just appeared.
    var matchFound = Timing.matchFound

    init() {}

    /// Every beat 0.
    static let instant: Beats = {
        var beats = Beats()
        beats.shellFlight = 0
        beats.apexHold = 0
        beats.apexTimeout = 0
        beats.impactLinger = 0
        beats.sinking = 0
        beats.sunkStamp = 0
        beats.stampHold = 0
        beats.whistle = 0
        beats.turnSting = 0
        beats.finaleCard = 0
        beats.finaleCardReduced = 0
        beats.catchUpStep = 0
        beats.opening = 0
        beats.matchFound = 0
        return beats
    }()
}

/// How many moves of each online game this device has already shown, so that the opponent's shots
/// made while the player was away can be replayed when the game is opened again. Kept in
/// `UserDefaults` under one key as `"<game id>:<count>"` entries, newest last, bounded like the
/// outcomes seen.
struct SeenMoveCounts {
    static let key = "seenMoveCounts"
    static let gamesKept = 300

    let defaults: UserDefaults

    func count(of gameID: UUID) -> Int? {
        let prefix = gameID.uuidString + ":"
        guard let entry = defaults.stringArray(forKey: Self.key)?.last(where: { $0.hasPrefix(prefix) }) else { return nil }
        return Int(entry.dropFirst(prefix.count))
    }

    /// Remembers that `count` moves have been shown, unless more already have.
    func mark(_ gameID: UUID, count: Int) {
        guard (self.count(of: gameID) ?? -1) < count else { return }
        let prefix = gameID.uuidString + ":"
        var entries = (defaults.stringArray(forKey: Self.key) ?? []).filter { !$0.hasPrefix(prefix) }
        entries.append(prefix + String(count))
        defaults.set(Array(entries.suffix(Self.gamesKept)), forKey: Self.key)
    }
}

/// Something one piece of work waits for another to finish: `wait()` suspends until `open()`, and
/// returns at once if the latch is already open.
@MainActor
private final class Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// A few beats at offsets from `play()`, on the main actor. Beats that are due run at once, before
/// `play()` returns (which is what keeps a battle with instant beats deterministic); the rest sleep on
/// a task until their time. `skip()` runs whatever is left immediately, in order; `cancel()` drops it.
@MainActor
private final class BattleSequence {
    struct Beat {
        let at: TimeInterval
        let run: @MainActor () -> Void
    }

    private let beats: [Beat]
    /// The first beat that hasn't run.
    private var next = 0
    private var task: Task<Void, Never>?
    private(set) var isPlaying = false

    init(_ beats: [Beat]) {
        // In time order; beats at the same offset keep the order they were given in.
        self.beats = beats.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
    }

    func play() {
        guard !isPlaying, next == 0 else { return }
        isPlaying = true
        let start = ContinuousClock.now
        runDueBeats(since: start)
        // A beat may have skipped or cancelled the sequence, or it may be over already.
        guard isPlaying else { return }
        if next >= beats.count {
            isPlaying = false
            return
        }
        task = Task { [weak self] in
            await self?.run(since: start)
        }
    }

    /// Runs every remaining beat immediately, in order.
    func skip() {
        guard isPlaying else { return }
        task?.cancel()
        task = nil
        while isPlaying, next < beats.count {
            let beat = beats[next]
            next += 1
            beat.run()
        }
        isPlaying = false
    }

    /// Stops without running anything else.
    func cancel() {
        task?.cancel()
        task = nil
        isPlaying = false
        next = beats.count
    }

    private func run(since start: ContinuousClock.Instant) async {
        while isPlaying, next < beats.count {
            do {
                try await Task.sleep(until: start + .seconds(beats[next].at), clock: .continuous)
            } catch {
                return   // skipped or cancelled: whoever did that ran or dropped the rest
            }
            guard isPlaying, !Task.isCancelled else { return }
            runDueBeats(since: start)
        }
        isPlaying = false
    }

    private func runDueBeats(since start: ContinuousClock.Instant) {
        while isPlaying, next < beats.count, start + .seconds(beats[next].at) <= ContinuousClock.now {
            let beat = beats[next]
            next += 1
            beat.run()
        }
    }
}

// MARK: - The controller

/// Drives one battle screen, for online games and games against the computer alike. It applies the
/// player's moves at once but reacts to nothing until the shell lands: the landing, the sinking, the
/// stamp, the enemy's telegraphed reply, the turn sting and the finale are beats on one timeline that
/// the boards, the haptics and the sounds follow together.
@MainActor
@Observable
final class BattleController {
    enum Phase: Equatable {
        case loading
        case unavailable(String)
        /// Matchmaking, or a challenge the other player hasn't answered.
        case waitingForOpponent
        /// Someone challenged the player, who hasn't answered yet.
        case challenged
        case battle
        case finished
    }

    struct Announcement: Identifiable, Equatable {
        /// Whose doing the news is, which decides how urgently VoiceOver reads it.
        enum Source: Equatable {
            /// The result of the player's own shot.
            case player
            case opponent
            case game
        }

        let id = UUID()
        let message: String
        let isGoodNews: Bool
        let source: Source
    }

    /// The feel of the moment, which colours the headline at the top of the battle.
    enum Mood: Equatable {
        case neutral
        /// The player's turn to fire.
        case ready
        /// Waiting on the opponent.
        case waiting
        /// The computer is about to fire.
        case danger
        case triumph
        case defeat
    }

    /// The start of a battle with no moves yet: BATTLE STATIONS, after a Match Found card when an
    /// online opponent has just been found. Input is closed while it plays; a tap skips it.
    enum Opening: Equatable, Sendable {
        case matchFound(start: Date)
        case playing(start: Date)
    }

    /// A shot whose consequences are waiting for its landing.
    private struct Landing {
        let id: UUID
        let move: Move
        /// Its place in the perspective's moves, for the count of moves seen.
        let index: Int
        let isMine: Bool
        var shellID: UUID?
        var lands: Date
        /// The shot ended the game: its landing is the finale.
        var isFinal = false
        /// Opened once the shot has landed, for whoever is waiting on it.
        var latch: Latch?
    }

    /// How long a misfired shell fizzles before it is forgotten.
    static let misfireLinger: TimeInterval = 0.6

    let route: GameRoute
    /// The cell the player has lined up. Tapping it again fires.
    var aimed: Coordinate?
    var errorMessage: String?
    var showsOutcome = false
    /// Set by the view from the motion policy: the outcome card comes sooner under Reduce Motion or VoiceOver.
    var prefersReducedFinale = false
    private(set) var isSubmitting = false
    private(set) var isComputerThinking = false
    /// News shown in a banner at the top of the battle.
    private(set) var announcement: Announcement?
    /// Everything VoiceOver should read out: the banners, and news too small for one, like a miss.
    private(set) var spokenAnnouncement: Announcement?
    private(set) var loadError: String?
    /// Counts the player's hits on the enemy, so the screen can react to each one.
    private(set) var hitsLanded = 0
    /// Counts the enemy's hits on the player's fleet.
    private(set) var hitsTaken = 0

    // The timeline the boards draw.

    /// Shells in the air.
    private(set) var shells: [ShellFlight] = []
    /// Shells that have landed, kept for `impactDuration`.
    private(set) var impacts: [Impact] = []
    /// The enemy's shell on its way to the home board.
    private(set) var telegraph: Telegraph?
    private(set) var sinkings: [Sinking] = []
    private(set) var stamps: [Stamp] = []
    private(set) var finale: Finale?
    private(set) var opening: Opening?
    /// Effect time on the enemy's waters: it stops for a moment at every landing.
    let targetClock = FXClock()
    /// Effect time on the player's waters.
    let homeClock = FXClock()
    /// An online shot has waited at the apex longer than `beats.apexTimeout`: the fire bar says TRANSMITTING.
    private(set) var isTransmitting = false
    /// The opponent's shots made while the player was away are being replayed; input is closed meanwhile.
    private(set) var isCatchingUp = false
    /// Bumped `beats.turnSting` after an enemy landing hands the turn back; views animate on the change.
    private(set) var turnStings = 0
    /// Consecutive hits by the player; a miss resets it.
    private(set) var hitStreak = 0
    private(set) var isEnemyOnLastShip = false
    private(set) var latestOwnShot: Coordinate?
    private(set) var latestEnemyShot: Coordinate?
    /// Bumped after `Timing.idleCue` seconds of the player's turn without input.
    private(set) var idleCueCount = 0
    /// The player's turn has gone `Timing.idleTier` seconds without input: views drop to the reduced tier.
    private(set) var isIdle = false
    /// Whose turn the HUD shows, which changes at the landing beats, not when the engine applies a
    /// move: the player's landing hands the turn over, the enemy's landing hands it back.
    private(set) var displayedTurn: Player?

    /// `impacts` as the boards drew them before `impacts` existed.
    var effects: [ImpactEffect] {
        impacts.map(ImpactEffect.init)
    }

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var seenMoveCount: Int?
    @ObservationIgnored private var hasHandledOutcome = false
    @ObservationIgnored private var hasOpened = false
    /// Whether `keepInStep()` is armed, so appearing again doesn't arm a second tracker.
    @ObservationIgnored private var isKeepingInStep = false
    /// The game was seen looking for an opponent, so when it becomes active one has just been found.
    @ObservationIgnored private var wasMatchmaking = false
    /// Whether the battle is on screen. Shots that land while it isn't are neither animated nor
    /// heard, and the end of the game waits to be shown until the player comes back.
    @ObservationIgnored private var isOnScreen = true
    /// Every sequence in flight, oldest first.
    @ObservationIgnored private var sequences: [BattleSequence] = []
    @ObservationIgnored private var openingSequence: BattleSequence?
    /// Shots fired but not landed, in firing order.
    @ObservationIgnored private var pendingLandings: [Landing] = []
    /// Who is waiting for the player's shell to land, by the shell.
    @ObservationIgnored private var shellLatches: [UUID: Latch] = [:]
    /// Opened when the computer's reply has landed, or been called off. Reserved at the player's
    /// landing when the reply waits for the stamp, so `fire()` can wait on it from the start.
    @ObservationIgnored private var computerTurn: Latch?
    /// The computer's pause, telegraph and shot are scheduled.
    @ObservationIgnored private var isComputerTurnPlaying = false
    @ObservationIgnored private var apexWatch: Task<Void, Never>?
    @ObservationIgnored private var idleWatch: Task<Void, Never>?
    /// How long each beat takes. Tests set `.instant`.
    @ObservationIgnored var beats = Beats()
    /// How long the computer seems to think before it fires, in milliseconds. Tests change it.
    @ObservationIgnored var computerPause: ClosedRange<Int> = 650...1100
    /// Where the counts of moves seen per online game are kept. Tests give each app its own.
    @ObservationIgnored var seenMoveCounts = SeenMoveCounts(defaults: .standard)

    /// How long a shell's splash or flame stays on the board: `beats.impactLinger` as a `Duration`.
    var impactDuration: Duration {
        get { .seconds(beats.impactLinger) }
        set { beats.impactLinger = Self.seconds(newValue) }
    }

    init(route: GameRoute, app: AppModel) {
        self.route = route
        self.app = app
    }

    // MARK: What's on screen

    var gameID: UUID {
        switch route {
        case let .online(id), let .solo(id): id
        }
    }

    var isSolo: Bool {
        if case .solo = route { return true }
        return false
    }

    var onlineGame: GameDetail? {
        guard case let .online(id) = route else { return nil }
        return app.online.details[id]
    }

    var soloMatch: ComputerMatch? {
        guard case let .solo(id) = route else { return nil }
        return app.solo.match(id)
    }

    var perspective: BattlePerspective? {
        switch route {
        case .online: onlineGame?.perspective
        case .solo: soloMatch?.perspective
        }
    }

    var mode: GameMode? {
        onlineGame?.summary.mode ?? soloMatch?.mode ?? app.online.summary(for: gameID)?.mode
    }

    /// The other player in an online game, for reporting or blocking them.
    var opponent: PlayerSummary? {
        guard case .online = route else { return nil }
        return app.online.summary(for: gameID)?.opponent
    }

    var phase: Phase {
        switch route {
        case let .online(id):
            guard app.isSignedIn else { return .unavailable("You're signed out. Sign in to see this battle.") }
            if let reason = app.online.removals[id] {
                return .unavailable(reason == .declined ? "Your challenge was declined." : "This game was called off.")
            }
            guard let game = onlineGame else {
                return loadError.map(Phase.unavailable) ?? .loading
            }
            switch game.summary.status {
            case .matchmaking: return .waitingForOpponent
            case .invited: return game.summary.isIncomingChallenge ? .challenged : .waitingForOpponent
            case .active: return .battle
            case .finished: return .finished
            }
        case .solo:
            guard let match = soloMatch else { return .unavailable("This game no longer exists.") }
            return match.isOver ? .finished : .battle
        }
    }

    var opponentName: String {
        if let match = soloMatch {
            return "Computer (\(match.difficulty.displayName))"
        }
        return app.online.summary(for: gameID)?.opponentName ?? "Opponent"
    }

    var opponentCaption: String? {
        if let match = soloMatch {
            return match.difficulty.tagline
        }
        return app.online.summary(for: gameID)?.opponent.map { "Rating \($0.rating)" }
    }

    /// One line describing the state of play, for the header.
    var statusLine: String {
        switch phase {
        case .loading:
            return "Loading…"
        case let .unavailable(reason):
            return reason
        case .waitingForOpponent:
            return onlineGame?.summary.status == .matchmaking
                ? "Searching for an opponent…"
                : "Waiting for \(opponentName) to accept…"
        case .challenged:
            return "\(opponentName) challenged you!"
        case .battle:
            if isComputerThinking { return "The computer is taking aim…" }
            guard perspective != nil else { return "" }
            return showsMyTurn ? "Pick a target in enemy waters." : "Waiting for \(opponentName) to fire…"
        case .finished:
            guard let perspective, let didWin = perspective.didWin else { return "Game over" }
            switch perspective.outcome?.reason {
            case .resignation:
                return didWin ? "Victory! \(opponentName) resigned." : "You resigned."
            case .timeout:
                return didWin ? "Victory! \(opponentName) ran out of time." : "Defeat. You ran out of time."
            case .fleetDestroyed, nil:
                return didWin ? "Victory! Enemy fleet destroyed." : "Defeat. Your fleet is gone."
            }
        }
    }

    /// A word or two for the top of the battle screen, like "Your turn".
    var headline: String {
        switch phase {
        case .loading: "Loading"
        case .unavailable: "Unavailable"
        case .waitingForOpponent: onlineGame?.summary.status == .matchmaking ? "Searching" : "Challenge sent"
        case .challenged: "Challenged"
        case .battle:
            if isComputerThinking { "Incoming" } else if showsMyTurn { "Your turn" } else { "Their turn" }
        case .finished: perspective?.didWin == true ? "Victory" : "Defeat"
        }
    }

    var mood: Mood {
        switch phase {
        case .battle:
            if isComputerThinking { .danger } else if showsMyTurn { .ready } else { .waiting }
        case .finished:
            perspective?.didWin == true ? .triumph : .defeat
        case .loading, .unavailable, .waitingForOpponent, .challenged:
            .neutral
        }
    }

    /// The HUD's turn is the player's. Until the first look at the game it is the engine's turn.
    private var showsMyTurn: Bool {
        guard let perspective else { return false }
        return (displayedTurn ?? perspective.turn) == perspective.me
    }

    /// The player may act: it is their turn on the HUD and nothing is in flight.
    var isMyTurn: Bool {
        phase == .battle && showsMyTurn && !isComputerThinking && !isSequenceClosingInput
    }

    var canFire: Bool {
        isMyTurn && aimed != nil && !isSubmitting
    }

    /// A battle with no moves yet that hasn't had its first look: its opening starts with that look
    /// (`syncMoves()`), so the screen shows the opening's readout from its first frame rather than
    /// offering a shot and a coach mark for the frame before BATTLE STATIONS.
    var awaitsOpening: Bool {
        phase == .battle && !hasOpened && perspective?.moves.isEmpty == true
    }

    /// A beat during which the player can't fire: the opening, their own shell in the air, the enemy's
    /// on its way, or the opponent's shots being replayed.
    private var isSequenceClosingInput: Bool {
        opening != nil || isCatchingUp || telegraph != nil || shells.contains { $0.outcome != .misfire }
    }

    /// The opponent has let their time to move run out, so the player can take the win.
    var canClaimVictory: Bool {
        phase == .battle && onlineGame?.summary.canClaimVictory() == true
    }

    // MARK: Lifecycle

    func viewDidAppear() {
        isOnScreen = true
        app.visibleGameID = gameID
        // Catch up on anything that happened while the player was away, such as the end of the game.
        syncMoves()
        // The app may have been closed, or the screen left, while the computer was about to move.
        if case let .solo(id) = route {
            startComputerTurn(in: id)
        }
        watchForIdleness()
        keepInStep()
    }

    func viewDidDisappear() {
        isOnScreen = false
        // Every sequence stops. The shots in it land at once, silently, so the board state is right
        // when the player comes back; the computer holds its fire until the game is opened again.
        for sequence in sequences {
            sequence.cancel()
        }
        sequences.removeAll()
        openingSequence = nil
        stopWatchingApex()
        idleWatch?.cancel()
        idleWatch = nil
        isIdle = false
        for landing in pendingLandings {
            land(landing.id, silently: true)
        }
        for latch in shellLatches.values {
            latch.open()
        }
        shellLatches.removeAll()
        finishComputerTurn()
        shells.removeAll()
        impacts.removeAll()
        telegraph = nil
        sinkings.removeAll()
        stamps.removeAll()
        finale = nil
        opening = nil
        isCatchingUp = false
        if case .online = route, let seen = seenMoveCount {
            seenMoveCounts.mark(gameID, count: seen)
        }
        if app.visibleGameID == gameID {
            app.visibleGameID = nil
        }
    }

    func load() async {
        switch route {
        case let .online(id):
            do {
                try await app.online.loadGame(id)
                loadError = nil
            } catch {
                if app.online.details[id] == nil {
                    loadError = error.userMessage
                }
            }
        case let .solo(id):
            syncMoves()
            // The app may have been closed while the computer was about to move.
            if let reply = startComputerTurn(in: id) ?? computerTurn {
                await reply.wait()
            }
        }
        syncMoves()
    }

    /// Runs every sequence in flight to its end at once (the opening ends, the shells land, the stamps
    /// fall, the finale shows its card) and clears what the boards were animating. The view calls it
    /// when the app goes to the background and when a sheet comes up over the battle.
    func skipSequences() {
        var rounds = 0
        while let sequence = sequences.first(where: { $0.isPlaying }), rounds < 64 {
            sequence.skip()
            rounds += 1
        }
        sequences.removeAll { !$0.isPlaying }
        openingSequence = nil
        opening = nil
        // A shell still waiting for the server stays in the air; everything else has landed.
        shells.removeAll { $0.lands != nil || $0.outcome != nil }
        impacts.removeAll()
        telegraph = nil
        sinkings.removeAll()
        stamps.removeAll()
        if finale != nil {
            finale = nil
            showsOutcome = true
        }
    }

    /// Tap to skip the finale: the outcome shows at once.
    func skipFinale() {
        guard finale != nil else { return }
        skipSequences()
    }

    /// Tap to skip the opening: the battle is playable at once.
    func skipOpening() {
        guard opening != nil else { return }
        openingSequence?.cancel()
        endOpening()
    }

    /// The player did something: they aren't idle. `tapTarget` and `fire` call it; the view calls it
    /// for gestures of its own.
    func noteInteraction() {
        watchForIdleness()
    }

    // MARK: Playing

    /// Aims at a cell, or fires if it's already aimed at.
    func tapTarget(_ coordinate: Coordinate) {
        noteInteraction()
        guard isMyTurn, !isSubmitting, let perspective else { return }
        guard perspective.canTarget(coordinate) else {
            app.feedback.play(.invalid)
            return
        }
        if aimed == coordinate {
            Task { await self.fire() }
        } else {
            aimed = coordinate
            app.feedback.play(.aim)
        }
    }

    /// Fires at the aimed cell. The move is made at once, but nothing is reacted to until the shell
    /// lands, `beats.shellFlight` later; this returns once it has, and in a game against the computer
    /// once the computer's reply has landed too.
    func fire() async {
        guard canFire, let target = aimed else { return }
        noteInteraction()
        isSubmitting = true
        // The turn is over, so nothing to be idle about.
        idleWatch?.cancel()
        idleWatch = nil
        app.feedback.play(.fire)
        let start = Date()
        let shell = ShellFlight(id: UUID(), board: .target, coordinate: target, start: start, lands: nil, outcome: nil)
        let landed = Latch()

        switch route {
        case let .online(id):
            // The shell waits at the apex until the server answers.
            shells.append(shell)
            shellLatches[shell.id] = landed
            watchApex(of: shell.id)
            do {
                _ = try await app.online.fire(id, at: target)
                stopWatchingApex()
                aimed = nil
                if let index = shells.firstIndex(where: { $0.id == shell.id }), shells[index].lands == nil {
                    shells[index].lands = apexLanding(for: shells[index], now: Date())
                }
                syncMoves()
                if let unclaimed = shellLatches.removeValue(forKey: shell.id) {
                    // The store doesn't show the move, so there is nothing to land.
                    shells.removeAll { $0.id == shell.id }
                    isSubmitting = false
                    unclaimed.open()
                }
                await landed.wait()
            } catch {
                stopWatchingApex()
                shellLatches[shell.id] = nil
                misfire(shell.id)
                errorMessage = error.userMessage
                app.feedback.play(.invalid)
                isSubmitting = false
                syncMoves()
            }

        case let .solo(id):
            guard var match = app.solo.match(id) else {
                isSubmitting = false
                return
            }
            do {
                try match.fire(at: target)
            } catch {
                errorMessage = error.userMessage
                isSubmitting = false
                return
            }
            aimed = nil
            var flying = shell
            flying.lands = start.addingTimeInterval(beats.shellFlight)
            shells.append(flying)
            shellLatches[shell.id] = landed
            app.solo.update(match)
            syncMoves()
            if let unclaimed = shellLatches.removeValue(forKey: shell.id) {
                shells.removeAll { $0.id == shell.id }
                isSubmitting = false
                unclaimed.open()
            }
            await landed.wait()
            if let reply = computerTurn {
                await reply.wait()
            }
        }
    }

    func resign() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        aimed = nil
        switch route {
        case let .online(id):
            do {
                try await app.online.resign(id)
            } catch {
                errorMessage = error.userMessage
            }
        case let .solo(id):
            guard var match = app.solo.match(id), (try? match.resign()) != nil else { return }
            app.solo.update(match)
        }
        syncMoves()
    }

    func claimVictory() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await app.online.claimVictory(gameID)
        } catch let error as APIError where error.code == .opponentStillHasTime {
            // This device's clock is ahead of the server's. Catch up with the real deadline.
            _ = try? await app.online.loadGame(gameID)
            announce("\(opponentName) still has a moment left to move.", isGoodNews: false, source: .game)
        } catch {
            errorMessage = error.userMessage
        }
        syncMoves()
    }

    /// Answers a challenge with the player's fleet. Returns whether it worked.
    func acceptChallenge(with fleet: [ShipPlacement]) async -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await app.online.accept(gameID, fleet: fleet)
            syncMoves()
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    func declineChallenge() async -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await app.online.decline(gameID)
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    /// Withdraws a game that hasn't started yet.
    func cancelGame() async -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await app.online.cancel(gameID)
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    // MARK: The shell

    /// When an online shell lands once the server has answered at `now`: it waits at the apex for the
    /// answer, so a slow answer only ever holds it there.
    private func apexLanding(for shell: ShellFlight, now: Date) -> Date {
        max(now, shell.start.addingTimeInterval(beats.apexHold)).addingTimeInterval(beats.shellFlight - beats.apexHold)
    }

    /// Says TRANSMITTING if the server hasn't answered within `beats.apexTimeout`.
    private func watchApex(of shellID: UUID) {
        apexWatch?.cancel()
        let timeout = beats.apexTimeout
        apexWatch = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, shells.contains(where: { $0.id == shellID && $0.lands == nil }) else { return }
            isTransmitting = true
        }
    }

    private func stopWatchingApex() {
        apexWatch?.cancel()
        apexWatch = nil
        isTransmitting = false
    }

    /// The request failed: the shell fizzles for a moment, then goes away.
    private func misfire(_ shellID: UUID) {
        guard let index = shells.firstIndex(where: { $0.id == shellID }) else { return }
        shells[index].outcome = .misfire
        schedule([BattleSequence.Beat(at: Self.misfireLinger) { [weak self] in
            self?.shells.removeAll { $0.id == shellID }
        }])
    }

    // MARK: The computer's turn

    /// Starts the computer's reply if it is the computer's turn: a pause of `computerPause` during
    /// which the HUD says it is taking aim, its shot telegraphed through the last `beats.whistle` of
    /// that, then the landing. Returns what to wait on for the landing, or nil if there is nothing to
    /// play. The target is picked now so that it can be telegraphed; the same seed on the same state
    /// picks it again when the shot is made.
    @discardableResult
    private func startComputerTurn(in id: UUID) -> Latch? {
        guard !isComputerTurnPlaying, let match = app.solo.match(id), match.isComputersTurn else { return nil }
        var generator = SeededRandomNumberGenerator(seed: UInt64.random(in: 0...UInt64.max))
        let replay = generator
        let target = match.opponent.chooseTarget(with: match.battle.intel(for: ComputerMatch.computer), using: &generator)
        let pause = TimeInterval(Int.random(in: computerPause)) / 1000
        let whistle = min(beats.whistle, pause)
        let reply = computerTurn ?? Latch()
        computerTurn = reply
        isComputerTurnPlaying = true
        isComputerThinking = true
        schedule([
            BattleSequence.Beat(at: pause - whistle) { [weak self] in
                // Unless the game ended during the pause: then there is no shot to announce.
                guard let self, app.solo.match(id)?.isComputersTurn == true else { return }
                telegraphIncoming(target, for: whistle, whistles: true)
            },
            BattleSequence.Beat(at: pause) { [weak self] in
                self?.computerFires(in: id, replay: replay)
            },
        ])
        return reply
    }

    /// Promises the computer's reply before it is started (it starts at the stamp after a sunk), so
    /// that `fire()` can wait on it meanwhile.
    private func reserveComputerTurn() {
        if computerTurn == nil {
            computerTurn = Latch()
        }
    }

    private func computerFires(in id: UUID, replay: SeededRandomNumberGenerator) {
        isComputerThinking = false
        if var match = app.solo.match(id), match.isComputersTurn {
            var again = replay
            match.playComputerTurn(using: &again)
            app.solo.update(match)
            syncMoves()
        }
        // The landing opens the latch; if nothing is going to land, nobody should wait for it.
        if !pendingLandings.contains(where: { !$0.isMine }) {
            finishComputerTurn()
        }
    }

    private func finishComputerTurn() {
        isComputerThinking = false
        isComputerTurnPlaying = false
        computerTurn?.open()
        computerTurn = nil
    }

    /// Shows where the enemy's shell will land, for `duration` before it does.
    private func telegraphIncoming(_ target: Coordinate, for duration: TimeInterval, whistles: Bool) {
        let now = Date()
        telegraph = Telegraph(coordinate: target, start: now, lands: now.addingTimeInterval(duration))
        app.feedback.play(.incoming)
        if whistles {
            app.feedback.play(.whistle)
        }
    }

    // MARK: Reacting to new shots

    /// Schedules the landing of every shot fired since the last call. The first call only takes note
    /// of the history, so opening a game doesn't replay every shot; in an online game it replays the
    /// opponent's shots made since the game was last on screen.
    func syncMoves() {
        // Noted before there is a board to look at (there is none while matchmaking), so that when
        // an opponent is found the opening leads with the Match Found card.
        if onlineGame?.summary.status == .matchmaking {
            wasMatchmaking = true
        }
        guard let perspective else { return }
        let moves = perspective.moves
        let isFirstLook = seenMoveCount == nil
        var incoming: [[BattleSequence.Beat]] = []
        if isFirstLook {
            isEnemyOnLastShip = perspective.enemyShipsRemaining == 1 && perspective.outcome == nil
            if case .online = route {
                if let seen = seenMoveCounts.count(of: gameID), seen < moves.count {
                    let unseen = (seen..<moves.count).filter { moves[$0].player != perspective.me }
                    if unseen.isEmpty {
                        seenMoveCounts.mark(gameID, count: moves.count)
                    } else {
                        incoming.append(catchUp(on: unseen, of: moves))
                    }
                } else {
                    seenMoveCounts.mark(gameID, count: moves.count)
                }
            }
        } else if let seen = seenMoveCount, moves.count > seen {
            for index in seen..<moves.count {
                incoming.append(landingBeats(for: moves[index], at: index, in: perspective))
            }
        }
        seenMoveCount = moves.count

        if let outcome = perspective.outcome, !hasHandledOutcome, isOnScreen {
            hasHandledOutcome = true
            // Opening a finished game shows how it ended only if the player hasn't seen that yet, e.g.
            // when the opponent's last shot landed while they were elsewhere.
            let isNews = !isFirstLook || !app.settings.hasSeenOutcome(of: gameID)
            app.settings.markOutcomeSeen(of: gameID)
            if isNews {
                if outcome.reason == .fleetDestroyed, let last = pendingLandings.indices.last, pendingLandings[last].index == moves.count - 1 {
                    // The shot that ended it is about to land: its landing is the finale.
                    pendingLandings[last].isFinal = true
                } else {
                    app.feedback.play(perspective.didWin == true ? .victory : .defeat)
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(900))
                        self?.showsOutcome = true
                    }
                }
            }
        }

        if !incoming.isEmpty, opening != nil {
            // A shot arriving during the opening ends it.
            skipOpening()
        }
        if phase == .battle, moves.isEmpty, !hasOpened, isOnScreen {
            hasOpened = true
            startOpening(matchFound: wasMatchmaking)
        }
        for beats in incoming {
            schedule(beats)
        }
        // With nothing in the air the HUD shows the engine's turn (a resignation, a challenge accepted,
        // a move made on another device).
        if pendingLandings.isEmpty, let current = self.perspective {
            displayedTurn = current.turn
        }
    }

    /// The beats of one new shot: the player's lands when its shell does, the computer's lands when
    /// its telegraph says, and an online opponent's is telegraphed for a whistle first.
    private func landingBeats(for move: Move, at index: Int, in perspective: BattlePerspective) -> [BattleSequence.Beat] {
        let isMine = move.player == perspective.me
        let now = Date()
        var landing = Landing(id: UUID(), move: move, index: index, isMine: isMine, shellID: nil, lands: now)
        var beats: [BattleSequence.Beat] = []
        if isMine {
            if let shellIndex = shells.firstIndex(where: { $0.board == .target && $0.coordinate == move.target && $0.outcome == nil }) {
                var shell = shells[shellIndex]
                if shell.lands == nil {
                    shell.lands = apexLanding(for: shell, now: now)
                }
                shell.outcome = Self.outcome(of: move.result)
                shells[shellIndex] = shell
                landing.shellID = shell.id
                landing.lands = max(now, shell.lands ?? now)
                landing.latch = shellLatches.removeValue(forKey: shell.id)
            }
        } else if let telegraph, telegraph.coordinate == move.target {
            landing.lands = max(now, telegraph.lands)
        } else if isOnScreen {
            // After the player's own shell, if that is still in the air.
            let start = max(now, pendingLandings.filter(\.isMine).map(\.lands).max() ?? now)
            let whistle = self.beats.whistle
            let target = move.target
            beats.append(BattleSequence.Beat(at: start.timeIntervalSince(now)) { [weak self] in
                self?.telegraphIncoming(target, for: whistle, whistles: true)
            })
            landing.lands = start.addingTimeInterval(whistle)
        }
        pendingLandings.append(landing)
        let landingID = landing.id
        beats.append(BattleSequence.Beat(at: max(0, landing.lands.timeIntervalSince(now))) { [weak self] in
            self?.land(landingID, silently: false)
        })
        return beats
    }

    /// Replays the opponent's shots at `indices`, `beats.catchUpStep` apart, each shown on its way for
    /// one step before it lands.
    private func catchUp(on indices: [Int], of moves: [Move]) -> [BattleSequence.Beat] {
        isCatchingUp = true
        let now = Date()
        let step = beats.catchUpStep
        var beats: [BattleSequence.Beat] = []
        for (slot, index) in indices.enumerated() {
            let move = moves[index]
            let at = TimeInterval(slot) * step
            let landing = Landing(id: UUID(), move: move, index: index, isMine: false, shellID: nil, lands: now.addingTimeInterval(at + step))
            pendingLandings.append(landing)
            let landingID = landing.id
            beats.append(BattleSequence.Beat(at: at) { [weak self] in
                self?.telegraphIncoming(move.target, for: step, whistles: false)
            })
            beats.append(BattleSequence.Beat(at: at + step) { [weak self] in
                self?.land(landingID, silently: false)
            })
        }
        let total = moves.count
        let end = TimeInterval(indices.count) * step
        beats.append(BattleSequence.Beat(at: end) { [weak self] in
            guard let self else { return }
            isCatchingUp = false
            seenMoveCounts.mark(gameID, count: total)
            watchForIdleness()
        })
        beats.append(BattleSequence.Beat(at: end + self.beats.turnSting) { [weak self] in
            guard let self, isMyTurn else { return }
            turnStings += 1
            app.feedback.play(.turnSting)
        })
        return beats
    }

    /// The consequences of a shot, at its landing. Silently (off screen): only the state that must be
    /// right when the player comes back, with nothing animated, heard or announced.
    private func land(_ landingID: UUID, silently: Bool) {
        guard let position = pendingLandings.firstIndex(where: { $0.id == landingID }) else { return }
        let landing = pendingLandings.remove(at: position)
        let move = landing.move
        let isMine = landing.isMine
        defer {
            if !isMine, isSolo {
                finishComputerTurn()
            }
            landing.latch?.open()
        }
        let isHit = move.result.isHit
        let isSunk: Bool = if case .sunk = move.result { true } else { false }
        let now = Date()

        if let shellID = landing.shellID {
            shells.removeAll { $0.id == shellID }
        }
        if isMine {
            latestOwnShot = move.target
            hitStreak = isHit ? hitStreak + 1 : 0
        } else {
            latestEnemyShot = move.target
            if telegraph?.coordinate == move.target {
                telegraph = nil
            }
        }
        if case .online = route {
            seenMoveCounts.mark(gameID, count: landing.index + 1)
        }
        let perspective = self.perspective
        if let perspective {
            let isOver = landing.isFinal || (perspective.outcome != nil && pendingLandings.isEmpty)
            displayedTurn = isOver ? nil : (isMine ? perspective.me.opponent : perspective.me)
        }
        let onLastShip = perspective.map { $0.enemyShipsRemaining == 1 && $0.outcome == nil } ?? false
        let lastShipNews = isMine && onLastShip && !isEnemyOnLastShip
        isEnemyOnLastShip = onLastShip

        guard !silently, isOnScreen, let perspective else {
            if isMine {
                isSubmitting = false
            }
            if landing.isFinal {
                showsOutcome = true
            }
            return
        }

        let board: BoardSide = isMine ? .target : .home
        let clock = isMine ? targetClock : homeClock
        if isHit {
            if isMine {
                hitsLanded += 1
            } else {
                hitsTaken += 1
            }
        }

        let isClose = !isHit && Self.isCloseMiss(move, isMine: isMine, in: perspective)
        let impact = Impact(
            id: UUID(), board: board, coordinate: move.target, isHit: isHit, isSunk: isSunk, isFinal: landing.isFinal, start: now,
            isClose: isClose
        )
        impacts.append(impact)
        // Where and whose the shot was shapes its sound and rumble: panned by column (mirrored for
        // shells on the player's waters), a take picked by the cell, duller on the player's own hull.
        let variation = FeedbackVariation(
            pan: Self.pan(for: move.target, in: perspective.rules, isMine: isMine),
            seed: Self.seed(for: move.target),
            isMine: isMine,
            isFinal: landing.isFinal
        )
        let impactID = impact.id
        schedule([BattleSequence.Beat(at: beats.impactLinger) { [weak self] in
            self?.impacts.removeAll { $0.id == impactID }
        }])

        if landing.isFinal {
            clock.hitStop(Timing.finalHitStop, at: now)
            clock.slowMotion(scale: Timing.finalTimeScale, for: Timing.finalSlowMotion, at: now)
            app.feedback.play(.finalBlow, variation: variation)
        } else {
            clock.hitStop(isSunk ? Timing.sunkHitStop : Timing.hitStop, at: now)
            switch move.result {
            case .miss: app.feedback.play(isClose ? .nearMiss : .miss, variation: variation)
            case .hit: app.feedback.play(isMine ? .hit : .hitOwn, variation: variation)
            case .sunk: app.feedback.play(isMine ? .sunk : .sunkOwn, variation: variation)
            }
        }
        announce(move, isMine: isMine)

        // Against the computer, its turn starts at the stamp when the player sank something.
        var computerWaitsForTheStamp = false
        if isSunk, let ship = isMine ? perspective.knownEnemyShip(at: move.target) : perspective.myShip(at: move.target) {
            let sinking = Sinking(id: UUID(), board: board, ship: ship, start: now)
            sinkings.append(sinking)
            let sinkingID = sinking.id
            computerWaitsForTheStamp = isMine && isSolo && !landing.isFinal
            let startsComputerTurn = computerWaitsForTheStamp
            if computerWaitsForTheStamp {
                // Promised now: with instant beats the stamp beat runs inside `schedule`, and the
                // turn it starts must be the one `fire()` is about to wait for.
                reserveComputerTurn()
            }
            schedule([
                BattleSequence.Beat(at: beats.sunkStamp) { [weak self] in
                    guard let self else { return }
                    stamp(ship, on: board)
                    if startsComputerTurn, case let .solo(id) = route, startComputerTurn(in: id) == nil, !isComputerTurnPlaying {
                        // Nothing to play after all (the game ended meanwhile): nobody waits for it.
                        finishComputerTurn()
                    }
                },
                BattleSequence.Beat(at: beats.sinking) { [weak self] in
                    self?.sinkings.removeAll { $0.id == sinkingID }
                },
            ])
        }
        if lastShipNews {
            // The enemy's last ship: the sting rises.
            app.feedback.play(.lastShip, variation: FeedbackVariation(isMine: false))
        }
        if isMine, isHit, hitStreak >= 3, hitStreak % 2 == 1 {
            app.feedback.play(.streak, variation: FeedbackVariation(count: hitStreak))
        }

        if landing.isFinal {
            let didWin = isMine
            finale = Finale(board: board, coordinate: move.target, start: now, didWin: didWin)
            schedule([
                BattleSequence.Beat(at: beats.sunkStamp) { [weak self] in
                    self?.app.feedback.play(didWin ? .victory : .defeat)
                },
                BattleSequence.Beat(at: prefersReducedFinale ? beats.finaleCardReduced : beats.finaleCard) { [weak self] in
                    self?.showsOutcome = true
                },
            ])
            if isMine {
                isSubmitting = false
            }
            return
        }

        if isMine {
            // Input reopens; against the computer its turn begins (at the stamp after a sunk).
            isSubmitting = false
            if case let .solo(id) = route, !computerWaitsForTheStamp {
                startComputerTurn(in: id)
            }
        } else if isMyTurn {
            schedule([BattleSequence.Beat(at: beats.turnSting) { [weak self] in
                guard let self, phase == .battle else { return }
                turnStings += 1
                app.feedback.play(.turnSting)
            }])
            watchForIdleness()
        }
    }

    private func stamp(_ ship: ShipPlacement, on board: BoardSide) {
        let stamp = Stamp(id: UUID(), board: board, ship: ship, start: Date())
        stamps.append(stamp)
        app.feedback.play(.stamp)
        let stampID = stamp.id
        schedule([BattleSequence.Beat(at: beats.stampHold) { [weak self] in
            self?.stamps.removeAll { $0.id == stampID }
        }])
    }

    /// Where a shot sounds from: its column across the stereo field (±0.6), mirrored for shells
    /// landing on the player's own waters.
    private static func pan(for target: Coordinate, in rules: Rules, isMine: Bool) -> Double {
        let half = Double(max(rules.boardSize - 1, 1)) / 2
        let across = (Double(target.column) - half) / half
        return min(1, max(-1, across * 0.6)) * (isMine ? 1 : -1)
    }

    /// A take for the cell, so the same square always sounds the same and neighbours differ.
    private static func seed(for target: Coordinate) -> Int {
        (target.row * 31 + target.column * 7) % 97 + 1
    }

    /// Whether a miss fell right beside one of the shooter's own earlier hits (public information
    /// on either board), which makes it a near miss.
    private static func isCloseMiss(_ move: Move, isMine: Bool, in perspective: BattlePerspective) -> Bool {
        let neighbours = [
            move.target.offsetBy(rows: -1, columns: 0), move.target.offsetBy(rows: 1, columns: 0),
            move.target.offsetBy(rows: 0, columns: -1), move.target.offsetBy(rows: 0, columns: 1),
        ]
        return neighbours.contains { cell in
            guard perspective.rules.contains(cell) else { return false }
            let mark = isMine ? perspective.targetMark(at: cell) : perspective.homeMark(at: cell)
            return mark == .hit || mark == .sunk
        }
    }

    private func announce(_ move: Move, isMine: Bool) {
        let source: Announcement.Source = isMine ? .player : .opponent
        switch move.result {
        case .miss:
            if isMine {
                // The splash says it all on screen; VoiceOver needs to hear it.
                announce("Miss at \(move.target).", isGoodNews: false, source: source, showsBanner: false)
            } else {
                announce("\(opponentName) fired at \(move.target) and missed.", isGoodNews: true, source: source)
            }
        case .hit:
            announce(isMine ? "Direct hit at \(move.target)!" : "\(opponentName) hit your ship at \(move.target)!", isGoodNews: isMine, source: source)
        case let .sunk(kind):
            announce(isMine ? "You sank their \(kind.displayName)!" : "\(opponentName) sank your \(kind.displayName)!", isGoodNews: isMine, source: source)
        }
    }

    private func announce(_ message: String, isGoodNews: Bool, source: Announcement.Source, showsBanner: Bool = true) {
        let announcement = Announcement(message: message, isGoodNews: isGoodNews, source: source)
        spokenAnnouncement = announcement
        guard showsBanner else { return }
        self.announcement = announcement
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Timing.bannerHold))
            if self?.announcement?.id == announcement.id {
                self?.announcement = nil
            }
        }
    }

    // MARK: The opening

    private func startOpening(matchFound: Bool) {
        let now = Date()
        var beats: [BattleSequence.Beat] = []
        var total: TimeInterval = 0
        if matchFound {
            opening = .matchFound(start: now)
            total = self.beats.matchFound
            beats.append(BattleSequence.Beat(at: total) { [weak self] in
                self?.opening = .playing(start: Date())
            })
        } else {
            opening = .playing(start: now)
        }
        total += self.beats.opening
        beats.append(BattleSequence.Beat(at: total) { [weak self] in
            self?.endOpening()
        })
        openingSequence = schedule(beats)
    }

    private func endOpening() {
        opening = nil
        openingSequence = nil
        watchForIdleness()
    }

    // MARK: Sequencing

    /// Plays `beats` as one sequence, remembered until it finishes so that leaving can cancel it and
    /// `skipSequences()` can run it out. Beats due at once run before this returns.
    @discardableResult
    private func schedule(_ beats: [BattleSequence.Beat]) -> BattleSequence {
        sequences.removeAll { !$0.isPlaying }
        let sequence = BattleSequence(beats)
        sequences.append(sequence)
        sequence.play()
        return sequence
    }

    /// Starts the idle timer over: `idleCueCount` bumps after `Timing.idleCue` seconds of the player's
    /// turn without input and `isIdle` follows after `Timing.idleTier`.
    private func watchForIdleness() {
        idleWatch?.cancel()
        idleWatch = nil
        isIdle = false
        guard isOnScreen, isMyTurn else { return }
        idleWatch = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Timing.idleCue))
                guard !Task.isCancelled else { return }
                self?.idleCueCount += 1
                try await Task.sleep(for: .seconds(Timing.idleTier - Timing.idleCue))
                guard !Task.isCancelled else { return }
                self?.isIdle = true
            } catch {
                // Input came, or the player left.
            }
        }
    }

    /// Follows the game while the battle is on screen, so that what the views don't report (an
    /// opponent found, a challenge accepted) still reaches `syncMoves()`. One change at a time: the
    /// tracking is armed again after each.
    private func keepInStep() {
        guard isOnScreen, !isKeepingInStep else { return }
        isKeepingInStep = true
        withObservationTracking {
            _ = phase
            _ = perspective?.turn
            _ = perspective?.moves.count
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isKeepingInStep = false
                guard isOnScreen else { return }
                syncMoves()
                keepInStep()
            }
        }
    }

    private static func outcome(of result: ShotResult) -> ShellFlight.Outcome {
        switch result {
        case .miss: .miss
        case .hit: .hit
        case .sunk: .sunk
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
