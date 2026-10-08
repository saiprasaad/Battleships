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
    /// A bcrypt hash, or ``noPassword`` for players who sign in with Apple or Google.
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

    /// Stored in place of a hash for players without a password. It isn't a bcrypt hash, so no
    /// password can match it, and sign-in rejects these players before checking anything. (A marker
    /// rather than NULL: SQLite can't relax the column's NOT NULL without rebuilding the users table.)
    static let noPassword = "!"

    var hasPassword: Bool {
        passwordHash != Self.noPassword
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

    /// Starts a session for `user` and returns its bearer token, clearing away everyone's expired
    /// sessions while it's there (devices they registered go with them, ON DELETE CASCADE). Call it
    /// under the write lock.
    static func startSession(for user: User, lifetime: TimeInterval, on db: any Database) async throws -> String {
        try await UserToken.query(on: db).filter(\.$expiresAt < Date()).delete()
        let (token, hash) = generate()
        try await UserToken(userID: try user.requireID(), tokenHash: hash, expiresAt: Date().addingTimeInterval(lifetime)).save(on: db)
        return token
    }
}

final class Device: Model, @unchecked Sendable {
    static let schema = "devices"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    /// The session that registered the device. Notifications stop when it expires, and signing out
    /// of it forgets the device. `nil` for devices registered before sessions were recorded; those
    /// keep getting notifications until the app registers them again (it does on every launch).
    @OptionalParent(key: "session_id") var session: UserToken?
    /// Hex-encoded APNs device token.
    @Field(key: "token") var token: String
    @Field(key: "environment") var environment: String
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(userID: UUID, sessionID: UUID?, token: String, environment: PushEnvironment) {
        self.$user.id = userID
        self.$session.id = sessionID
        self.token = token
        self.environment = environment.rawValue
    }

    var pushEnvironment: PushEnvironment {
        PushEnvironment(rawValue: environment) ?? .production
    }
}
