import JWTKit
import Vapor

/// Checks identity tokens issued by Apple or Google.
protocol IdentityTokenVerifying: Sendable {
    /// The account ID (the token's `sub`), once the token's signature and claims check out. `nonce`
    /// is the value its `nonce` claim must have. Throws ``AppError/invalidIdentityToken`` otherwise.
    func subject(of token: String, nonce: String) async throws -> String
}

/// Fetches the keys a provider signs its tokens with.
protocol KeySetFetching: Sendable {
    func keySet(at url: URI) async throws -> JWKS
}

/// Who issues a kind of identity token, and what the tokens must say.
struct IdentityTokenIssuer: Sendable {
    let provider: IdentityProvider
    /// Where the provider publishes its signing keys.
    let keySetURL: URI
    let issuers: Set<String>
    let audience: String

    static func apple(bundleID: String) -> IdentityTokenIssuer {
        IdentityTokenIssuer(
            provider: .apple,
            keySetURL: "https://appleid.apple.com/auth/keys",
            issuers: ["https://appleid.apple.com"],
            audience: bundleID
        )
    }

    static func google(clientID: String) -> IdentityTokenIssuer {
        IdentityTokenIssuer(
            provider: .google,
            keySetURL: "https://www.googleapis.com/oauth2/v3/certs",
            issuers: ["accounts.google.com", "https://accounts.google.com"],
            audience: clientID
        )
    }
}

/// The claims checked in an Apple or Google identity token. The app asks for no name or email.
struct IdentityClaims: JWTPayload {
    var iss: IssuerClaim
    var aud: AudienceClaim
    var exp: ExpirationClaim
    var sub: SubjectClaim
    var nonce: String?

    /// ``JWKSIdentityTokenVerifier`` checks the claims itself: what they must say depends on the provider.
    func verify(using algorithm: some JWTAlgorithm) async throws {}
}

/// Verifies RS256 identity tokens against the keys their provider publishes. The keys are cached,
/// and fetched again when a token names one that isn't known yet (providers rotate them) or once
/// they're a day old.
actor JWKSIdentityTokenVerifier: IdentityTokenVerifying {
    /// How far past its expiry a token is still accepted, for clocks that disagree a little.
    static let clockLeeway: TimeInterval = 60
    /// The most often keys are fetched, so tokens naming made-up keys can't hammer the provider.
    static let refetchInterval: TimeInterval = 60
    static let maximumKeyAge: TimeInterval = 24 * 60 * 60

    private let issuer: IdentityTokenIssuer
    private let fetcher: any KeySetFetching
    private let logger: Logger
    private let now: @Sendable () -> Date
    private var keys = JWTKeyCollection()
    private var keyIDs: Set<String> = []
    private var fetchedAt: Date?
    private var lastAttempt: Date?

    init(_ issuer: IdentityTokenIssuer, fetcher: any KeySetFetching, logger: Logger, now: @escaping @Sendable () -> Date = Date.init) {
        self.issuer = issuer
        self.fetcher = fetcher
        self.logger = logger
        self.now = now
    }

    func subject(of token: String, nonce: String) async throws -> String {
        do {
            return try await verify(token, nonce: nonce)
        } catch let error as AppError {
            throw error
        } catch {
            // Why, but never the token itself.
            logger.notice("Rejected a \(issuer.provider.displayName) identity token: \(error)")
            throw AppError.invalidIdentityToken
        }
    }

    private func verify(_ token: String, nonce: String) async throws -> String {
        let header = try DefaultJWTParser().parse(Array(token.utf8), as: IdentityClaims.self).header
        guard header.alg == "RS256" else {
            throw IdentityTokenRejection("signed with \(header.alg ?? "nothing") rather than RS256")
        }
        guard let keyID = header.kid else { throw IdentityTokenRejection("no key ID") }
        try await loadKeys(including: keyID)
        guard keyIDs.contains(keyID) else { throw IdentityTokenRejection("signed with an unknown key") }

        let claims = try await keys.verify(token, as: IdentityClaims.self)
        guard issuer.issuers.contains(claims.iss.value) else { throw IdentityTokenRejection("wrong issuer") }
        guard claims.aud.value.contains(issuer.audience) else { throw IdentityTokenRejection("wrong audience") }
        guard claims.exp.value.addingTimeInterval(Self.clockLeeway) > now() else { throw IdentityTokenRejection("expired") }
        guard claims.nonce == nonce else { throw IdentityTokenRejection("wrong nonce") }
        guard !claims.sub.value.isEmpty else { throw IdentityTokenRejection("no subject") }
        return claims.sub.value
    }

    /// Fetches the provider's keys if they're missing, old, or don't include `keyID`.
    private func loadKeys(including keyID: String) async throws {
        let now = self.now()
        let stale = fetchedAt.map { now.timeIntervalSince($0) > Self.maximumKeyAge } ?? true
        let triedRecently = lastAttempt.map { now.timeIntervalSince($0) < Self.refetchInterval } ?? false
        if (stale || !keyIDs.contains(keyID)) && !triedRecently {
            lastAttempt = now
            do {
                let keySet = try await fetcher.keySet(at: issuer.keySetURL)
                let collection = JWTKeyCollection()
                var ids: Set<String> = []
                for key in keySet.keys where key.keyType == .rsa && (key.algorithm == nil || key.algorithm == .rs256) {
                    guard let id = key.keyIdentifier?.string else { continue }
                    // Never a default key: a token naming an unknown key must not be checked against another.
                    try await collection.add(jwk: key, isDefault: false)
                    ids.insert(id)
                }
                keys = collection
                keyIDs = ids
                fetchedAt = now
            } catch {
                // Keep the keys there are: a provider outage shouldn't sign everyone out.
                logger.warning("Could not fetch \(issuer.provider.displayName)'s signing keys: \(error)")
            }
        }
        guard !keyIDs.isEmpty else { throw AppError.identityCheckUnavailable(issuer.provider) }
    }
}

/// Why an identity token was turned down, for the log.
struct IdentityTokenRejection: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Fetches key sets over HTTPS with the application's HTTP client.
struct HTTPKeySetFetcher: KeySetFetching {
    let client: any Client

    func keySet(at url: URI) async throws -> JWKS {
        let response = try await client.get(url) { $0.timeout = .seconds(10) }
        guard response.status == .ok, let body = response.body else {
            throw Abort(.badGateway, reason: "\(url) answered \(response.status.code)")
        }
        return try JSONDecoder().decode(JWKS.self, from: body)
    }
}
