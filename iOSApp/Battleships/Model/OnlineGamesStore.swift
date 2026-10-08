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

    init(api: APIClient) {
        self.api = api
        self.realtime = RealtimeClient(api: api)
    }

    func summary(for id: UUID) -> GameSummary? {
        details[id]?.summary ?? summaries.first { $0.id == id }
    }

    // MARK: Loading

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            summaries = try await api.games()
            hasLoaded = true
            refreshError = nil
        } catch is CancellationError {
            // The view went away; nothing to report.
        } catch {
            refreshError = error.userMessage
        }
    }

    @discardableResult
    func loadGame(_ id: UUID) async throws -> GameDetail {
        let detail = try await api.game(id: id)
        apply(detail)
        return detail
    }

    /// Records a newer version of a game. Out-of-order updates (a slow response arriving after a
    /// realtime event, say) are ignored, because games only ever move forward.
    func apply(_ detail: GameDetail) {
        if let existing = details[detail.id], Self.isStale(detail, comparedTo: existing) {
            return
        }
        details[detail.id] = detail
        removals[detail.id] = nil
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
        summaries.removeAll { $0.id == id }
        details[id] = nil
        if let reason {
            removals[id] = reason
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
        realtimeTask = Task { [weak self] in
            for await update in updates {
                await self?.handle(update)
            }
            self?.realtimeTask = nil
            self?.connection = .offline
        }
    }

    func disconnect() {
        realtimeTask?.cancel()
        realtimeTask = nil
        connection = .offline
    }

    /// Forgets everything, e.g. on sign-out.
    func reset() {
        disconnect()
        summaries = []
        details = [:]
        removals = [:]
        hasLoaded = false
        refreshError = nil
    }

    private func handle(_ update: RealtimeUpdate) async {
        switch update {
        case .connected:
            connection = .live
            // Catch up on anything that happened while the connection was down.
            await refresh()
            for id in details.keys {
                _ = try? await loadGame(id)
            }
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
}
