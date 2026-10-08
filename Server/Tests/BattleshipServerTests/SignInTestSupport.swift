@testable import BattleshipServer
import CryptoExtras
import JWTKit
import XCTVapor

/// Serves the key sets the tests' providers sign with, in place of Apple's and Google's.
actor TestKeySets: KeySetFetching {
    private var published: [String: JWKS] = [:]
    private(set) var fetches: [String] = []

    func publish(_ keySet: JWKS, at url: URI) {
        published[url.string] = keySet
    }

    func unpublish(_ url: URI) {
        published[url.string] = nil
    }

    func keySet(at url: URI) async throws -> JWKS {
        fetches.append(url.string)
        guard let keySet = published[url.string] else { throw Abort(.serviceUnavailable) }
        return keySet
    }
}

/// Stands in for Apple's token and revoke endpoints, and remembers what it was asked.
actor RecordingAppleTokens: AppleTokenClient {
    private(set) var exchangedCodes: [String] = []
    private(set) var revokedTokens: [String] = []
    private var refusesExchanges = false

    func refuseExchanges(_ refuses: Bool) {
        refusesExchanges = refuses
    }

    func refreshToken(forAuthorizationCode code: String) async throws -> String? {
        exchangedCodes.append(code)
        if refusesExchanges {
            throw AppleTokenError(status: .badRequest, body: ByteBuffer(string: #"{"error":"invalid_grant"}"#))
        }
        return "refresh-for-\(code)"
    }

    func revoke(refreshToken: String) async throws {
        revokedTokens.append(refreshToken)
    }
}

/// Plays Apple or Google: an RSA key that signs identity tokens, and the key set publishing it.
struct TestIdentityProvider: Sendable {
    let issuer: String
    let audience: String
    let keyID: String
    let keySet: JWKS
    private let signer: JWTKeyCollection

    /// The claims an identity token can carry; tests leave out or change them as they please.
    struct Claims: JWTPayload {
        var iss: IssuerClaim
        var aud: AudienceClaim
        var exp: ExpirationClaim
        var sub: SubjectClaim
        var nonce: String?

        func verify(using algorithm: some JWTAlgorithm) async throws {}
    }

    init(issuer: String, audience: String, keyID: String) async throws {
        let key = try Insecure.RSA.PrivateKey(backing: _RSA.Signing.PrivateKey(keySize: .bits2048))
        signer = JWTKeyCollection()
        await signer.add(rsa: key, digestAlgorithm: .sha256, kid: JWKIdentifier(string: keyID))
        let (modulus, exponent) = try key.publicKey.getKeyPrimitives()
        keySet = JWKS(keys: [
            .rsa(.rs256, identifier: JWKIdentifier(string: keyID), modulus: modulus.base64URLEncoded, exponent: exponent.base64URLEncoded),
        ])
        self.issuer = issuer
        self.audience = audience
        self.keyID = keyID
    }

    static func apple(keyID: String = "apple-key-1") async throws -> TestIdentityProvider {
        try await TestIdentityProvider(issuer: "https://appleid.apple.com", audience: ExternalSignInTests.bundleID, keyID: keyID)
    }

    static func google(keyID: String = "google-key-1") async throws -> TestIdentityProvider {
        try await TestIdentityProvider(issuer: "https://accounts.google.com", audience: ExternalSignInTests.googleClientID, keyID: keyID)
    }

    /// A signed identity token. By default it's valid for this provider.
    func token(
        subject: String,
        nonce: String?,
        issuer: String? = nil,
        audience: String? = nil,
        expiresIn: TimeInterval = 600,
        keyID: String? = nil
    ) async throws -> String {
        let claims = Claims(
            iss: IssuerClaim(value: issuer ?? self.issuer),
            aud: AudienceClaim(value: [audience ?? self.audience]),
            exp: ExpirationClaim(value: Date().addingTimeInterval(expiresIn)),
            sub: SubjectClaim(value: subject),
            nonce: nonce
        )
        var header = JWTHeader()
        header.kid = keyID ?? self.keyID
        return try await signer.sign(claims, header: header)
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    /// The lowercase hex SHA-256 the app puts in Sign in with Apple requests in place of the nonce.
    var sha256Hex: String {
        SHA256.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
