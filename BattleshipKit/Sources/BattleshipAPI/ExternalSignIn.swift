import Foundation

/// `GET /v1/auth/providers`: the ways of signing in this server accepts besides a username and
/// password, so the app only offers what works.
public struct AuthProviders: Codable, Sendable, Hashable {
    /// Sign in with Apple is set up on the server.
    public var apple: Bool
    /// The OAuth client ID of the server's Google Cloud "iOS" client, if Sign in with Google is set up.
    public var googleClientID: String?

    public init(apple: Bool, googleClientID: String? = nil) {
        self.apple = apple
        self.googleClientID = googleClientID
    }

    /// Neither Apple nor Google.
    public static let none = AuthProviders(apple: false)
}

/// `POST /v1/auth/apple`: the credential Sign in with Apple handed the app. The app asks Apple for
/// no name or email, so the token only identifies the Apple account.
public struct AppleSignInRequest: Codable, Sendable, Hashable {
    /// The identity token, a JWT signed by Apple.
    public var identityToken: String
    /// A single-use code the server exchanges for a refresh token, so that it can revoke the app's
    /// access to the Apple ID when the account is deleted.
    public var authorizationCode: String?
    /// The random nonce whose SHA-256 (in hex) the app put in the request. The token must carry
    /// that hash, which stops a token from being replayed.
    public var nonce: String

    public init(identityToken: String, authorizationCode: String?, nonce: String) {
        self.identityToken = identityToken
        self.authorizationCode = authorizationCode
        self.nonce = nonce
    }
}

/// `POST /v1/auth/google`: an ID token from Google, obtained with the `openid` scope only.
public struct GoogleSignInRequest: Codable, Sendable, Hashable {
    /// The ID token, a JWT signed by Google.
    public var idToken: String
    /// The nonce the app put in the authorization request. The token must carry it unchanged.
    public var nonce: String

    public init(idToken: String, nonce: String) {
        self.idToken = idToken
        self.nonce = nonce
    }
}

/// The answer to signing in with Apple or Google. Exactly one of ``session`` and ``signupTicket``
/// is set.
public struct ExternalSignInResponse: Codable, Sendable, Hashable {
    /// Set when an account is already linked to the Apple or Google account: the new session.
    public var session: AuthResponse?
    /// Set the first time an Apple or Google account is used. Pass it to
    /// `POST /v1/auth/complete-signup` with a username to create the account. Expires after
    /// ``signupTicketLifetime``.
    public var signupTicket: String?
    /// A free username to offer, along with a ``signupTicket``.
    public var suggestedUsername: String?

    public init(session: AuthResponse? = nil, signupTicket: String? = nil, suggestedUsername: String? = nil) {
        self.session = session
        self.signupTicket = signupTicket
        self.suggestedUsername = suggestedUsername
    }

    /// How long a signup ticket stays valid.
    public static let signupTicketLifetime: TimeInterval = 30 * 60
}

/// `POST /v1/auth/complete-signup`: creates the account for a new Apple or Google sign-in.
public struct CompleteSignupRequest: Codable, Sendable, Hashable {
    public var signupTicket: String
    public var username: String

    public init(signupTicket: String, username: String) {
        self.signupTicket = signupTicket
        self.username = username
    }
}
