import BattleshipAPI
import BattleshipClient
import BattleshipCore
import Foundation
import Observation

/// The player's online games, kept current by the realtime connection.
@MainActor
@Observable
final class OnlineGamesStore {
    enum Connection: Equatable {
        case offline
        case connecting
        case live
    }

    /// Lobby rows, as last reported by the server.
    private(set) var summaries: [GameSummary] = []
    /// Full games the player has opened.
    private(set) var details: [UUID: GameDetail] = [:]
    /// Games the other player withdrew or declined, so an open battle screen can explain what happened.
    private(set) var removals: [UUID: GameRemovalReason] = [:]
    private(set) var connection: Connection = .offline
    private(set) var hasLoaded = false
    private(set) var isRefreshing = false
    private(set) var refreshError: String?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let realtime: RealtimeClient
    @ObservationIgnored private var realtimeTask: Task<Void, Never>?
    /// Tells the current realtime task apart from one that is still winding down.
    @ObservationIgnored private var realtimeID: UUID?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshesAgain = false
    /// Games changed by realtime events or actions while a refresh was in flight. They're newer
    /// than the list the refresh brings back, so they win.
    @ObservationIgnored private var changedDuringRefresh: Set<UUID>?
    /// Games known to be gone. Games are never revived, so late news about them is ignored.
    @ObservationIgnored private var removedIDs: Set<UUID> = []
    /// Bumped by ``reset()`` so that work started for an earlier session doesn't land in this one.
    @ObservationIgnored private var generation = 0

    init(api: APIClient) {
        self.api = api
        self.realtime = RealtimeClient(api: api)
    }

    func summary(for id: UUID) -> GameSummary? {
        details[id]?.summary ?? summaries.first { $0.id == id }
    }

    // MARK: Loading

    /// Reloads the lobby. If a refresh is already running, waits for it and then refreshes once more,
    /// so whatever prompted this call is reflected.
    func refresh() async {
        if let refreshTask {
            refreshesAgain = true
            await refreshTask.value
            return
        }
        let task = Task { await runRefreshes() }
        refreshTask = task
        await task.value
    }

    private func runRefreshes() async {
        let generation = generation
        isRefreshing = true
        repeat {
            refreshesAgain = false
            await refreshOnce()
        } while refreshesAgain && generation == self.generation
        // After a reset, the new session's state isn't this task's to touch.
        guard generation == self.generation else { return }
        isRefreshing = false
        refreshTask = nil
    }

    private func refreshOnce() async {
        let generation = generation
        changedDuringRefresh = []
        defer {
            if generation == self.generation {
                changedDuringRefresh = nil
            }
        }
        do {
            let fresh = try await api.games()
            guard generation == self.generation else { return }
            merge(fresh)
            hasLoaded = true
            refreshError = nil
        } catch is CancellationError {
            // The connection went away; nothing to report.
        } catch {
            guard generation == self.generation else { return }
            refreshError = error.userMessage
        }
    }

    /// Takes the server's list, keeping anything that changed while it was on its way.
    private func merge(_ fresh: [GameSummary]) {
        let changed = changedDuringRefresh ?? []
        var merged = fresh.compactMap { summary -> GameSummary? in
            if removedIDs.contains(summary.id) { return nil }
            if changed.contains(summary.id) { return self.summary(for: summary.id) }
            return summary
        }
        let listed = Set(merged.map(\.id))
        for id in changed where !listed.contains(id) {
            if let summary = summary(for: id) {
                merged.insert(summary, at: 0)
            }
        }
        summaries = merged

        // The server lists every unfinished game, so an unfinished game missing from the list was
        // declined or withdrawn while the app wasn't listening.
        let current = Set(merged.map(\.id))
        for (id, detail) in details where detail.summary.status != .finished && !current.contains(id) {
            remove(id, reason: .cancelled)
        }
    }

    @discardableResult
    func loadGame(_ id: UUID) async throws -> GameDetail {
        let generation = generation
        do {
            let detail = try await api.game(id: id)
            if generation == self.generation {
                apply(detail)
            }
            return detail
        } catch let error as APIError where error.code == .gameNotFound {
            if generation == self.generation {
                remove(id, reason: .cancelled)
            }
            throw error
        }
    }

    /// Records a newer version of a game. Out-of-order updates (a slow response arriving after a
    /// realtime event, say) are ignored, because games only ever move forward.
    func apply(_ detail: GameDetail) {
        guard !removedIDs.contains(detail.id) else { return }
        if let existing = details[detail.id], Self.isStale(detail, comparedTo: existing) {
            return
        }
        details[detail.id] = detail
        removals[detail.id] = nil
        changedDuringRefresh?.insert(detail.id)
        if let index = summaries.firstIndex(where: { $0.id == detail.id }) {
            summaries[index] = detail.summary
        } else {
            summaries.insert(detail.summary, at: 0)
        }
    }

    nonisolated static func isStale(_ incoming: GameDetail, comparedTo existing: GameDetail) -> Bool {
        if incoming.moves.count != existing.moves.count {
            return incoming.moves.count < existing.moves.count
        }
        return stage(of: incoming.summary.status) < stage(of: existing.summary.status)
    }

    private nonisolated static func stage(of status: GameStatus) -> Int {
        switch status {
        case .matchmaking, .invited: 0
        case .active: 1
        case .finished: 2
        }
    }

    func remove(_ id: UUID, reason: GameRemovalReason?) {
        removedIDs.insert(id)
        changedDuringRefresh?.insert(id)
        summaries.removeAll { $0.id == id }
        details[id] = nil
        if let reason {
            removals[id] = reason
        }
    }

    /// Drops challenges to or from a player, e.g. after blocking them (the server withdraws them too).
    func removeChallenges(involving playerID: UUID) {
        let challenges = summaries.filter { $0.status == .invited && $0.opponent?.id == playerID }
        for challenge in challenges {
            remove(challenge.id, reason: .cancelled)
        }
    }

    // MARK: Actions

    func create(_ request: CreateGameRequest) async throws -> GameDetail {
        let detail = try await api.createGame(request)
        apply(detail)
        return detail
    }

    func accept(_ id: UUID, fleet: [ShipPlacement]) async throws -> GameDetail {
        let detail = try await api.acceptChallenge(gameID: id, fleet: fleet)
        apply(detail)
        return detail
    }

    func decline(_ id: UUID) async throws {
        try await api.declineChallenge(gameID: id)
        remove(id, reason: nil)
    }

    func cancel(_ id: UUID) async throws {
        try await api.cancelGame(gameID: id)
        remove(id, reason: nil)
    }

    func resign(_ id: UUID) async throws {
        apply(try await api.resign(gameID: id))
    }

    func claimVictory(_ id: UUID) async throws {
        apply(try await api.claimVictory(gameID: id))
    }

    func fire(_ id: UUID, at target: Coordinate) async throws -> Move {
        let response = try await api.fire(gameID: id, at: target)
        apply(response.game)
        return response.move
    }

    // MARK: Realtime

    /// Opens the live connection (if it isn't already open). Safe to call repeatedly.
    func connect() {
        guard realtimeTask == nil else { return }
        connection = .connecting
        let updates = realtime.updates()
        let id = UUID()
        realtimeID = id
        realtimeTask = Task { [weak self] in
            for await update in updates {
                self?.handle(update)
            }
            guard let self, self.realtimeID == id else { return }
            self.realtimeTask = nil
            self.realtimeID = nil
            self.connection = .offline
        }
    }

    func disconnect() {
        realtimeTask?.cancel()
        realtimeTask = nil
        realtimeID = nil
        connection = .offline
    }

    /// Forgets everything, e.g. on sign-out.
    func reset() {
        disconnect()
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshesAgain = false
        changedDuringRefresh = nil
        isRefreshing = false
        summaries = []
        details = [:]
        removals = [:]
        removedIDs = []
        hasLoaded = false
        refreshError = nil
    }

    private func handle(_ update: RealtimeUpdate) {
        switch update {
        case .connected:
            connection = .live
            // Catch up on anything that happened while the connection was down, without holding up
            // the live events queued behind this one.
            Task { await catchUp() }
        case .disconnected:
            connection = .connecting
        case .event(.hello):
            break
        case let .event(.gameUpdated(detail)):
            apply(detail)
        case let .event(.gameRemoved(gameID, reason)):
            remove(gameID, reason: reason)
        }
    }

    private func catchUp() async {
        await refresh()
        // Finished games don't change, so only the open ones need reloading.
        let open = details.values.filter { $0.summary.status != .finished }.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in open {
                group.addTask { _ = try? await self.loadGame(id) }
            }
        }
    }
}
