import JWTKit
import Vapor

/// Sign in with Apple's REST API, for the two things the server needs from it.
protocol AppleTokenClient: Sendable {
    /// Exchanges an authorization code from the app for a refresh token (`nil` if Apple sent none).
    func refreshToken(forAuthorizationCode code: String) async throws -> String?
    /// Revokes a refresh token, and with it the app's access to the player's Apple ID.
    func revoke(refreshToken: String) async throws
}

/// ``AppleTokenClient`` over HTTPS, authenticated by a client secret signed with the Sign in with
/// Apple key.
struct AppleTokenService: AppleTokenClient {
    /// Sends a form and returns Apple's answer.
    typealias FormPoster = @Sendable (_ url: URI, _ form: [String: String]) async throws -> (status: HTTPStatus, body: ByteBuffer?)

    static let tokenURL: URI = "https://appleid.apple.com/auth/token"
    static let revokeURL: URI = "https://appleid.apple.com/auth/revoke"
    /// Apple accepts client secrets valid for up to six months; each one here is made fresh.
    static let clientSecretLifetime: TimeInterval = 60 * 60

    private let bundleID: String
    private let key: ServerSettings.AppleSignInKey
    private let signer: JWTKeyCollection
    private let post: FormPoster

    init(bundleID: String, key: ServerSettings.AppleSignInKey, post: @escaping FormPoster) async throws {
        self.bundleID = bundleID
        self.key = key
        self.post = post
        signer = JWTKeyCollection()
        await signer.add(ecdsa: try ES256PrivateKey(pem: key.privateKeyPEM), kid: JWKIdentifier(string: key.keyID))
    }

    /// Posts forms with the application's HTTP client.
    static func poster(using client: any Client) -> FormPoster {
        { url, form in
            let response = try await client.post(url) { request in
                try request.content.encode(form, as: .urlEncodedForm)
                request.timeout = .seconds(10)
            }
            return (response.status, response.body)
        }
    }

    func refreshToken(forAuthorizationCode code: String) async throws -> String? {
        struct TokenResponse: Decodable {
            let refreshToken: String?

            enum CodingKeys: String, CodingKey {
                case refreshToken = "refresh_token"
            }
        }
        let (status, body) = try await post(Self.tokenURL, [
            "client_id": bundleID,
            "client_secret": try await clientSecret(),
            "code": code,
            "grant_type": "authorization_code",
        ])
        guard status == .ok, let body else { throw AppleTokenError(status: status, body: body) }
        return try JSONDecoder().decode(TokenResponse.self, from: body).refreshToken
    }

    func revoke(refreshToken: String) async throws {
        let (status, body) = try await post(Self.revokeURL, [
            "client_id": bundleID,
            "client_secret": try await clientSecret(),
            "token": refreshToken,
            "token_type_hint": "refresh_token",
        ])
        guard status == .ok else { throw AppleTokenError(status: status, body: body) }
    }

    /// A JWT that identifies this server to Apple.
    func clientSecret(now: Date = Date()) async throws -> String {
        let claims = AppleClientSecret(
            iss: IssuerClaim(value: key.teamID),
            iat: IssuedAtClaim(value: now),
            exp: ExpirationClaim(value: now.addingTimeInterval(Self.clientSecretLifetime)),
            aud: AudienceClaim(value: ["https://appleid.apple.com"]),
            sub: SubjectClaim(value: bundleID)
        )
        return try await signer.sign(claims, kid: JWKIdentifier(string: key.keyID))
    }
}

/// The claims of the client secret for Apple's token and revoke endpoints.
struct AppleClientSecret: JWTPayload {
    var iss: IssuerClaim
    var iat: IssuedAtClaim
    var exp: ExpirationClaim
    var aud: AudienceClaim
    var sub: SubjectClaim

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}

/// A request Apple refused. Describes itself by Apple's error code (like `invalid_grant`) only, so
/// nothing secret ends up in the log.
struct AppleTokenError: Error, CustomStringConvertible {
    let status: HTTPStatus
    let code: String?

    init(status: HTTPStatus, body: ByteBuffer?) {
        struct ErrorResponse: Decodable {
            let error: String
        }
        self.status = status
        code = body.flatMap { try? JSONDecoder().decode(ErrorResponse.self, from: $0).error }
    }

    var description: String {
        "Apple answered \(status.code)" + (code.map { " (\($0))" } ?? "")
    }
}
