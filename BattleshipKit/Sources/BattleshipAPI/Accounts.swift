import Foundation

/// Username and password, sent to register or sign in.
public struct Credentials: Codable, Sendable, Hashable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public struct PlayerStats: Codable, Sendable, Hashable {
    /// Elo rating; everyone starts at ``CredentialPolicy/startingRating``.
    public var rating: Int
    public var wins: Int
    public var losses: Int

    public init(rating: Int, wins: Int, losses: Int) {
        self.rating = rating
        self.wins = wins
        self.losses = losses
    }

    public var gamesPlayed: Int { wins + losses }

    public var winRate: Double? {
        gamesPlayed == 0 ? nil : Double(wins) / Double(gamesPlayed)
    }
}

/// The signed-in user.
public struct Account: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var username: String
    public var createdAt: Date
    public var stats: PlayerStats

    public init(id: UUID, username: String, createdAt: Date, stats: PlayerStats) {
        self.id = id
        self.username = username
        self.createdAt = createdAt
        self.stats = stats
    }
}

/// Returned by register and sign-in. Send `token` as `Authorization: Bearer <token>`.
public struct AuthResponse: Codable, Sendable, Hashable {
    public var token: String
    public var account: Account

    public init(token: String, account: Account) {
        self.token = token
        self.account = account
    }
}

/// Another player, as shown in game lists, search results and the leaderboard.
public struct PlayerSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var username: String
    public var rating: Int

    public init(id: UUID, username: String, rating: Int) {
        self.id = id
        self.username = username
        self.rating = rating
    }
}

public struct LeaderboardEntry: Codable, Sendable, Hashable, Identifiable {
    public var rank: Int
    public var player: PlayerSummary
    public var wins: Int
    public var losses: Int

    public init(rank: Int, player: PlayerSummary, wins: Int, losses: Int) {
        self.rank = rank
        self.player = player
        self.wins = wins
        self.losses = losses
    }

    public var id: UUID { player.id }
}

/// Rules for usernames and passwords, shared so the app can validate before the server does.
public enum CredentialPolicy {
    public static let usernameLength = 3...20
    public static let passwordLength = 8...128
    public static let startingRating = 1000

    /// A reason `username` is unacceptable, or `nil` if it is fine.
    public static func usernameProblem(_ username: String) -> String? {
        guard usernameLength.contains(username.count) else {
            return "Usernames are \(usernameLength.lowerBound)–\(usernameLength.upperBound) characters."
        }
        let allowed = username.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
        }
        guard allowed else {
            return "Usernames can only use letters, numbers and underscores."
        }
        return nil
    }

    /// A reason `password` is unacceptable, or `nil` if it is fine.
    public static func passwordProblem(_ password: String) -> String? {
        guard password.count >= passwordLength.lowerBound else {
            return "Passwords need at least \(passwordLength.lowerBound) characters."
        }
        guard password.count <= passwordLength.upperBound else {
            return "Passwords can be at most \(passwordLength.upperBound) characters."
        }
        return nil
    }

    /// The case-insensitive form used to keep usernames unique.
    public static func normalized(_ username: String) -> String {
        username.lowercased()
    }
}
