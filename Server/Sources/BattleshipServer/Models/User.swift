import BattleshipAPI
import Fluent
import Vapor

final class User: Model, Authenticatable, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    /// As the player typed it, e.g. "Captain_Nemo".
    @Field(key: "username") var username: String
    /// Lower-cased, for case-insensitive uniqueness and lookups.
    @Field(key: "username_key") var usernameKey: String
    @Field(key: "password_hash") var passwordHash: String
    @Field(key: "rating") var rating: Int
    @Field(key: "wins") var wins: Int
    @Field(key: "losses") var losses: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(username: String, passwordHash: String) {
        self.username = username
        self.usernameKey = CredentialPolicy.normalized(username)
        self.passwordHash = passwordHash
        self.rating = CredentialPolicy.startingRating
        self.wins = 0
        self.losses = 0
    }

    var stats: PlayerStats {
        PlayerStats(rating: rating, wins: wins, losses: losses)
    }

    func account() throws -> Account {
        Account(id: try requireID(), username: username, createdAt: createdAt ?? Date(), stats: stats)
    }

    func summary() throws -> PlayerSummary {
        PlayerSummary(id: try requireID(), username: username, rating: rating)
    }
}

final class UserToken: Model, Authenticatable, @unchecked Sendable {
    static let schema = "user_tokens"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    /// SHA-256 of the bearer token. The token itself is only ever shown to the client once.
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "expires_at") var expiresAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userID: UUID, tokenHash: String, expiresAt: Date) {
        self.$user.id = userID
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
    }

    /// A new random bearer token and the hash to store for it.
    static func generate() -> (token: String, hash: String) {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let token = bytes.hexString
        return (token, hash(token))
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).hexString
    }
}

final class Device: Model, @unchecked Sendable {
    static let schema = "devices"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    /// Hex-encoded APNs device token.
    @Field(key: "token") var token: String
    @Field(key: "environment") var environment: String
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(userID: UUID, token: String, environment: PushEnvironment) {
        self.$user.id = userID
        self.token = token
        self.environment = environment.rawValue
    }

    var pushEnvironment: PushEnvironment {
        PushEnvironment(rawValue: environment) ?? .production
    }
}
