import BattleshipAPI
import BattleshipCore
import Foundation

/// Where a lobby row leads.
enum GameRoute: Hashable, Sendable {
    case online(UUID)
    case solo(UUID)
}

enum LobbySection: Int, CaseIterable, Comparable, Sendable {
    case challenges
    case yourTurn
    case waiting
    case finished

    var title: String {
        switch self {
        case .challenges: "Challenges"
        case .yourTurn: "Your Move"
        case .waiting: "Waiting"
        case .finished: "Finished"
        }
    }

    static func < (lhs: LobbySection, rhs: LobbySection) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One row in the lobby: an online game or a game against the computer.
enum LobbyEntry: Identifiable, Hashable, Sendable {
    case online(GameSummary)
    case solo(ComputerMatch)

    var id: UUID {
        switch self {
        case let .online(game): game.id
        case let .solo(match): match.id
        }
    }

    var route: GameRoute {
        switch self {
        case let .online(game): .online(game.id)
        case let .solo(match): .solo(match.id)
        }
    }

    var updatedAt: Date {
        switch self {
        case let .online(game): game.updatedAt
        case let .solo(match): match.updatedAt
        }
    }

    var mode: GameMode {
        switch self {
        case let .online(game): game.mode
        case let .solo(match): match.mode
        }
    }

    var section: LobbySection {
        switch self {
        case let .online(game):
            switch game.status {
            case .invited where game.isIncomingChallenge: .challenges
            case .active where game.isYourTurn: .yourTurn
            case .finished: .finished
            default: .waiting
            }
        case let .solo(match):
            match.isOver ? .finished : .yourTurn
        }
    }

    var opponentName: String {
        switch self {
        case let .online(game): game.opponentName
        case let .solo(match): "Computer · \(match.difficulty.displayName)"
        }
    }

    /// A one-line description of where the game stands.
    var status: String {
        switch self {
        case let .online(game):
            switch game.status {
            case .matchmaking:
                return "Looking for an opponent…"
            case .invited:
                return game.isIncomingChallenge ? "Challenged you" : "Waiting for them to accept"
            case .active:
                let fleet = "\(game.yourShipsRemaining) vs \(game.opponentShipsRemaining) ships"
                if game.canClaimVictory() {
                    return "Their time is up · claim the win"
                }
                return game.isYourTurn ? "Your move · \(fleet)" : "Their move · \(fleet)"
            case .finished:
                return Self.result(didWin: game.didWin == true, reason: game.outcome?.reason)
            }
        case let .solo(match):
            let view = match.perspective
            if let didWin = view.didWin {
                return Self.result(didWin: didWin, reason: view.outcome?.reason)
            }
            return "Your move · \(view.myShipsRemaining) vs \(view.enemyShipsRemaining) ships"
        }
    }

    var didWin: Bool? {
        switch self {
        case let .online(game): game.didWin
        case let .solo(match): match.perspective.didWin
        }
    }

    private static func result(didWin: Bool, reason: Outcome.Reason?) -> String {
        switch (didWin, reason) {
        case (true, .resignation): "Won · opponent resigned"
        case (true, .timeout): "Won · opponent ran out of time"
        case (true, _): "Won"
        case (false, .resignation): "Lost · resigned"
        case (false, .timeout): "Lost · ran out of time"
        case (false, _): "Lost"
        }
    }
}

struct LobbyGroup: Identifiable, Hashable, Sendable {
    let section: LobbySection
    let entries: [LobbyEntry]

    var id: LobbySection { section }
}

enum Lobby {
    static let finishedGamesShown = 20

    /// Arranges games into lobby sections, most recent activity first. Empty sections are left out.
    static func groups(online: [GameSummary], solo: [ComputerMatch]) -> [LobbyGroup] {
        let entries = online.map(LobbyEntry.online) + solo.map(LobbyEntry.solo)
        let grouped = Dictionary(grouping: entries, by: \.section)
        return LobbySection.allCases.compactMap { section in
            guard let entries = grouped[section], !entries.isEmpty else { return nil }
            var sorted = entries.sorted { $0.updatedAt > $1.updatedAt }
            if section == .finished {
                sorted = Array(sorted.prefix(finishedGamesShown))
            }
            return LobbyGroup(section: section, entries: sorted)
        }
    }
}
