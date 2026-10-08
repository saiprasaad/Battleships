import BattleshipAPI
import BattleshipClient
import Foundation
import Observation

/// Blocking and reporting other players (App Store guideline 1.2). A blocked player can't challenge
/// the player or be matched with them, doesn't turn up in search, and any challenge between the
/// two is withdrawn.
@MainActor
@Observable
final class ModerationStore {
    /// The players this player has blocked, most recently blocked first.
    private(set) var blockedPlayers: [PlayerSummary] = []
    private(set) var hasLoadedBlockedPlayers = false
    private(set) var loadError: String?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let online: OnlineGamesStore

    init(api: APIClient, online: OnlineGamesStore) {
        self.api = api
        self.online = online
    }

    func isBlocked(_ playerID: UUID) -> Bool {
        blockedPlayers.contains { $0.id == playerID }
    }

    func loadBlockedPlayers() async {
        let token = api.token
        do {
            let players = try await api.blockedPlayers()
            guard api.token == token else { return }
            blockedPlayers = players
            hasLoadedBlockedPlayers = true
            loadError = nil
        } catch is CancellationError {
            // The screen went away; nothing to report.
        } catch {
            guard api.token == token else { return }
            loadError = error.userMessage
        }
    }

    func block(_ player: PlayerSummary) async throws {
        let token = api.token
        try await api.block(playerID: player.id)
        guard api.token == token else { return }
        if !isBlocked(player.id) {
            blockedPlayers.insert(player, at: 0)
        }
        // The server has withdrawn any challenge between the two players.
        online.removeChallenges(involving: player.id)
    }

    func unblock(_ player: PlayerSummary) async throws {
        let token = api.token
        try await api.unblock(playerID: player.id)
        guard api.token == token else { return }
        blockedPlayers.removeAll { $0.id == player.id }
    }

    /// Tells the people running the server about a player, optionally pointing at the game it's about.
    func report(_ player: PlayerSummary, reason: ReportReason, gameID: UUID? = nil) async throws {
        try await api.report(playerID: player.id, reason: reason, gameID: gameID)
    }

    /// Forgets everything, e.g. on sign-out.
    func reset() {
        blockedPlayers = []
        hasLoadedBlockedPlayers = false
        loadError = nil
    }
}
