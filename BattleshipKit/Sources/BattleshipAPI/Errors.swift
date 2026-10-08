/// Machine-readable error identifiers. Unknown codes from a newer server decode fine.
public struct APIErrorCode: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let badRequest: APIErrorCode = "bad_request"
    public static let unauthorized: APIErrorCode = "unauthorized"
    public static let forbidden: APIErrorCode = "forbidden"
    public static let notFound: APIErrorCode = "not_found"
    public static let rateLimited: APIErrorCode = "rate_limited"
    public static let internalError: APIErrorCode = "internal_error"

    public static let invalidUsername: APIErrorCode = "invalid_username"
    public static let invalidPassword: APIErrorCode = "invalid_password"
    public static let usernameTaken: APIErrorCode = "username_taken"
    public static let invalidCredentials: APIErrorCode = "invalid_credentials"
    /// An Apple or Google token that didn't verify (bad signature, wrong app, expired, wrong nonce).
    public static let invalidIdentityToken: APIErrorCode = "invalid_identity_token"
    /// The server isn't set up for that way of signing in.
    public static let signInMethodUnavailable: APIErrorCode = "sign_in_method_unavailable"
    /// A signup ticket that expired or was already used: sign in with Apple or Google again.
    public static let signupTicketInvalid: APIErrorCode = "signup_ticket_invalid"

    public static let invalidFleet: APIErrorCode = "invalid_fleet"
    public static let playerNotFound: APIErrorCode = "player_not_found"
    public static let cannotChallengeYourself: APIErrorCode = "cannot_challenge_yourself"
    public static let tooManyGames: APIErrorCode = "too_many_games"
    public static let gameNotFound: APIErrorCode = "game_not_found"
    public static let invalidGameState: APIErrorCode = "invalid_game_state"
    public static let notYourTurn: APIErrorCode = "not_your_turn"
    public static let alreadyTargeted: APIErrorCode = "already_targeted"
    public static let outOfBounds: APIErrorCode = "out_of_bounds"
    public static let gameOver: APIErrorCode = "game_over"
    public static let opponentStillHasTime: APIErrorCode = "opponent_still_has_time"
    public static let playerBlocked: APIErrorCode = "player_blocked"
}

/// The JSON body of every non-2xx response: `{"code": "not_your_turn", "message": "It's not your turn."}`.
public struct APIErrorBody: Codable, Sendable, Hashable, Error {
    public var code: APIErrorCode
    public var message: String

    public init(code: APIErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}
