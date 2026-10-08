import Fluent
import Vapor

/// The services players can sign in with besides a username and password.
enum IdentityProvider: String, Codable, Sendable {
    case apple
    case google

    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        }
    }
}

/// An Apple or Google account linked to a player, who signs in with it instead of a password.
final class ExternalIdentity: Model, @unchecked Sendable {
    static let schema = "external_identities"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "provider") var providerRaw: String
    /// The provider's stable identifier for the account (the token's `sub`).
    @Field(key: "subject") var subject: String
    /// Lets the server revoke the app's access to the Apple ID when the account is deleted, as Apple
    /// requires. A secret: never logged.
    @OptionalField(key: "apple_refresh_token") var appleRefreshToken: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userID: UUID, provider: IdentityProvider, subject: String, appleRefreshToken: String?) {
        self.$user.id = userID
        self.providerRaw = provider.rawValue
        self.subject = subject
        self.appleRefreshToken = appleRefreshToken
    }

    static func find(_ provider: IdentityProvider, subject: String, on db: any Database) async throws -> ExternalIdentity? {
        try await ExternalIdentity.query(on: db)
            .filter(\.$providerRaw == provider.rawValue)
            .filter(\.$subject == subject)
            .with(\.$user)
            .first()
    }
}

/// A first sign-in with Apple or Google, waiting for the player to pick a username. Single use.
final class SignupTicket: Model, @unchecked Sendable {
    static let schema = "signup_tickets"

    @ID(key: .id) var id: UUID?
    /// SHA-256 of the ticket. The ticket itself is only ever shown to the client once.
    @Field(key: "ticket_hash") var ticketHash: String
    @Field(key: "provider") var providerRaw: String
    @Field(key: "subject") var subject: String
    @OptionalField(key: "apple_refresh_token") var appleRefreshToken: String?
    @Field(key: "expires_at") var expiresAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(ticketHash: String, provider: IdentityProvider, subject: String, appleRefreshToken: String?, expiresAt: Date) {
        self.ticketHash = ticketHash
        self.providerRaw = provider.rawValue
        self.subject = subject
        self.appleRefreshToken = appleRefreshToken
        self.expiresAt = expiresAt
    }

    var provider: IdentityProvider? {
        IdentityProvider(rawValue: providerRaw)
    }
}
