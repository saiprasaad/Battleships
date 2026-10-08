import BattleshipCore
import Foundation

/// Who the player wants to fight.
enum OpponentChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
    case computer
    case randomPlayer
    case friend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .computer: "Computer"
        case .randomPlayer: "Random Opponent"
        case .friend: "A Friend"
        }
    }

    var subtitle: String {
        switch self {
        case .computer: "Play offline, right now"
        case .randomPlayer: "Get matched with another captain"
        case .friend: "Challenge someone by username"
        }
    }

    var systemImage: String {
        switch self {
        case .computer: "cpu"
        case .randomPlayer: "globe.americas.fill"
        case .friend: "person.2.fill"
        }
    }

    var isOnline: Bool { self != .computer }
}

/// The choices made in the New Battle sheet.
struct NewGameDraft: Hashable, Sendable {
    var opponent: OpponentChoice = .computer
    var difficulty: Difficulty = .medium
    var mode: GameMode = .classic
    var friendUsername = ""

    var trimmedFriendUsername: String {
        friendUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether everything needed to start has been chosen.
    var isComplete: Bool {
        opponent != .friend || !trimmedFriendUsername.isEmpty
    }
}
