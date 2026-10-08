import BattleshipAPI
import BattleshipCore
import Foundation
import Observation

/// A shell landing on a board, animated briefly where it hit.
struct ImpactEffect: Identifiable, Equatable, Sendable {
    enum Board: Sendable {
        case target
        case home
    }

    let id = UUID()
    let board: Board
    let coordinate: Coordinate
    let isHit: Bool
}

/// Drives one battle screen, for online games and games against the computer alike.
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
        let id = UUID()
        let message: String
        let isGoodNews: Bool
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

    let route: GameRoute
    /// The cell the player has lined up. Tapping it again fires.
    var aimed: Coordinate?
    var errorMessage: String?
    var showsOutcome = false
    private(set) var isSubmitting = false
    private(set) var isComputerThinking = false
    private(set) var effects: [ImpactEffect] = []
    private(set) var announcement: Announcement?
    private(set) var loadError: String?
    /// Counts the player's hits on the enemy, so the screen can react to each one.
    private(set) var hitsLanded = 0
    /// Counts the enemy's hits on the player's fleet.
    private(set) var hitsTaken = 0

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var seenMoveCount: Int?
    @ObservationIgnored private var hasHandledOutcome = false

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

    var phase: Phase {
        switch route {
        case let .online(id):
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
            guard let perspective else { return "" }
            return perspective.isMyTurn ? "Pick a target in enemy waters." : "Waiting for \(opponentName) to fire…"
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
            if isComputerThinking { "Incoming" } else if perspective?.isMyTurn == true { "Your turn" } else { "Their turn" }
        case .finished: perspective?.didWin == true ? "Victory" : "Defeat"
        }
    }

    var mood: Mood {
        switch phase {
        case .battle:
            if isComputerThinking { .danger } else if perspective?.isMyTurn == true { .ready } else { .waiting }
        case .finished:
            perspective?.didWin == true ? .triumph : .defeat
        case .loading, .unavailable, .waitingForOpponent, .challenged:
            .neutral
        }
    }

    var isMyTurn: Bool {
        phase == .battle && perspective?.isMyTurn == true && !isComputerThinking
    }

    var canFire: Bool {
        isMyTurn && aimed != nil && !isSubmitting
    }

    /// The opponent has let their time to move run out, so the player can take the win.
    var canClaimVictory: Bool {
        phase == .battle && onlineGame?.summary.canClaimVictory() == true
    }

    // MARK: Lifecycle

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
            await playComputerTurn(in: id)
        }
        syncMoves()
    }

    // MARK: Playing

    /// Aims at a cell, or fires if it's already aimed at.
    func tapTarget(_ coordinate: Coordinate) {
        guard isMyTurn, !isSubmitting, let perspective else { return }
        guard perspective.canTarget(coordinate) else {
            app.feedback.play(.invalid)
            return
        }
        if aimed == coordinate {
            Task { await fire() }
        } else {
            aimed = coordinate
            app.feedback.play(.aim)
        }
    }

    func fire() async {
        guard canFire, let target = aimed else { return }
        isSubmitting = true
        app.feedback.play(.fire)

        switch route {
        case let .online(id):
            do {
                _ = try await app.online.fire(id, at: target)
                aimed = nil
            } catch {
                errorMessage = error.userMessage
                app.feedback.play(.invalid)
            }
            isSubmitting = false
            syncMoves()

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
            app.solo.update(match)
            isSubmitting = false
            syncMoves()
            await playComputerTurn(in: id)
        }
    }

    func resign() async {
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
        do {
            try await app.online.claimVictory(gameID)
        } catch {
            errorMessage = error.userMessage
        }
        syncMoves()
    }

    /// Answers a challenge with the player's fleet. Returns whether it worked.
    func acceptChallenge(with fleet: [ShipPlacement]) async -> Bool {
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
        do {
            try await app.online.cancel(gameID)
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    private func playComputerTurn(in id: UUID) async {
        guard let match = app.solo.match(id), match.isComputersTurn else { return }
        isComputerThinking = true
        // A short pause so the player can watch the shot land, as if the computer were thinking.
        try? await Task.sleep(for: .milliseconds(Int.random(in: 650...1100)))
        if var latest = app.solo.match(id), latest.isComputersTurn {
            latest.playComputerTurn()
            app.solo.update(latest)
        }
        isComputerThinking = false
        syncMoves()
    }

    // MARK: Reacting to new shots

    /// Animates and announces shots fired since the last call. The first call only takes note of
    /// the history, so opening a game doesn't replay every shot.
    func syncMoves() {
        guard let perspective else { return }
        let moves = perspective.moves
        let isFirstLook = seenMoveCount == nil
        if let seen = seenMoveCount, moves.count > seen {
            for move in moves[seen...] {
                react(to: move, in: perspective)
            }
        }
        seenMoveCount = moves.count

        guard perspective.outcome != nil, !hasHandledOutcome else { return }
        hasHandledOutcome = true
        guard !isFirstLook else { return }
        app.feedback.play(perspective.didWin == true ? .victory : .defeat)
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            showsOutcome = true
        }
    }

    private func react(to move: Move, in perspective: BattlePerspective) {
        let isMine = move.player == perspective.me
        let effect = ImpactEffect(board: isMine ? .target : .home, coordinate: move.target, isHit: move.result.isHit)
        effects.append(effect)
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            effects.removeAll { $0.id == effect.id }
        }

        if !isMine {
            app.feedback.play(.incoming)
        }
        if move.result.isHit {
            if isMine {
                hitsLanded += 1
            } else {
                hitsTaken += 1
            }
        }

        switch move.result {
        case .miss:
            app.feedback.play(.miss)
            if !isMine {
                announce("\(opponentName) fired at \(move.target) and missed.", isGoodNews: true)
            }
        case .hit:
            app.feedback.play(.hit)
            announce(isMine ? "Direct hit at \(move.target)!" : "\(opponentName) hit your ship at \(move.target)!", isGoodNews: isMine)
        case let .sunk(kind):
            app.feedback.play(.sunk)
            announce(isMine ? "You sank their \(kind.displayName)!" : "\(opponentName) sank your \(kind.displayName)!", isGoodNews: isMine)
        }
    }

    private func announce(_ message: String, isGoodNews: Bool) {
        let announcement = Announcement(message: message, isGoodNews: isGoodNews)
        self.announcement = announcement
        Task {
            try? await Task.sleep(for: .milliseconds(2400))
            if self.announcement?.id == announcement.id {
                self.announcement = nil
            }
        }
    }
}
