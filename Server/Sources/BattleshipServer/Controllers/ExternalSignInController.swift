import BattleshipAPI
import Fluent
import Vapor

/// Signing in with Apple or Google, under `/v1/auth`. The first time an Apple or Google account is
/// used, the player gets a signup ticket and picks a username (`complete-signup`); after that,
/// signing in returns a session straight away.
struct ExternalSignInController: RouteCollection {
    /// Suggested usernames are one of these and a number, like "Captain4821".
    static let suggestionStems = ["Captain", "Admiral", "Commodore", "Skipper", "Navigator", "Bosun", "Helmsman", "Lookout"]

    let services: AppServices

    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")
            .grouped(RateLimitMiddleware(limiter: services.authRateLimiter, addressSource: services.settings.clientAddressSource))
        auth.get("providers", use: providers)
        auth.post("apple", use: apple)
        auth.post("google", use: google)
        auth.post("complete-signup", use: completeSignup)
    }

    @Sendable
    func providers(req: Request) -> AuthProviders {
        AuthProviders(apple: services.appleIdentity != nil, googleClientID: services.settings.googleClientID)
    }

    @Sendable
    func apple(req: Request) async throws -> ExternalSignInResponse {
        guard let verifier = services.appleIdentity else { throw AppError.signInUnavailable(.apple) }
        let body = try req.content.decode(AppleSignInRequest.self)
        guard !body.nonce.isEmpty else { throw AppError.badRequest("The sign-in is missing its nonce.") }
        // The app gives Apple the nonce's SHA-256, so that's what the token carries.
        let nonceHash = SHA256.hash(data: Data(body.nonce.utf8)).hexString
        let subject = try await verifier.subject(of: body.identityToken, nonce: nonceHash)
        return try await signIn(.apple, subject: subject, authorizationCode: body.authorizationCode, on: req)
    }

    @Sendable
    func google(req: Request) async throws -> ExternalSignInResponse {
        guard let verifier = services.googleIdentity else { throw AppError.signInUnavailable(.google) }
        let body = try req.content.decode(GoogleSignInRequest.self)
        guard !body.nonce.isEmpty else { throw AppError.badRequest("The sign-in is missing its nonce.") }
        let subject = try await verifier.subject(of: body.idToken, nonce: body.nonce)
        return try await signIn(.google, subject: subject, authorizationCode: nil, on: req)
    }

    /// Signs in the player linked to the account, or starts a sign-up for a new one.
    private func signIn(
        _ provider: IdentityProvider,
        subject: String,
        authorizationCode: String?,
        on req: Request
    ) async throws -> ExternalSignInResponse {
        let db = req.db
        let lifetime = services.settings.sessionLifetime

        if let identity = try await ExternalIdentity.find(provider, subject: subject, on: db) {
            // Without a refresh token the app's access can't be revoked later, so try again for one
            // if the exchange failed at sign-up.
            if provider == .apple, identity.appleRefreshToken == nil, let refreshToken = await exchange(authorizationCode, on: req) {
                identity.appleRefreshToken = refreshToken
                try await services.writeLock.withLock { try await identity.save(on: db) }
            }
            let user = identity.user
            let token = try await services.writeLock.withLock {
                try await UserToken.startSession(for: user, lifetime: lifetime, on: db)
            }
            return ExternalSignInResponse(session: AuthResponse(token: token, account: try user.account()))
        }

        // Network I/O, so before taking the write lock.
        let refreshToken = provider == .apple ? await exchange(authorizationCode, on: req) : nil
        let (ticket, ticketHash) = UserToken.generate()
        let expiresAt = Date().addingTimeInterval(ExternalSignInResponse.signupTicketLifetime)
        try await services.writeLock.withLock {
            try await SignupTicket.query(on: db).filter(\.$expiresAt < Date()).delete()
            try await SignupTicket(
                ticketHash: ticketHash,
                provider: provider,
                subject: subject,
                appleRefreshToken: refreshToken,
                expiresAt: expiresAt
            ).save(on: db)
        }
        return ExternalSignInResponse(signupTicket: ticket, suggestedUsername: try await suggestedUsername(on: db))
    }

    /// Creates the account for a signup ticket, with the username the player chose.
    @Sendable
    func completeSignup(req: Request) async throws -> Response {
        let body = try req.content.decode(CompleteSignupRequest.self)
        let username = try AuthController.validNewUsername(body.username, settings: services.settings)
        let ticketHash = UserToken.hash(body.signupTicket)
        let lifetime = services.settings.sessionLifetime
        let db = req.db

        let (response, created) = try await services.writeLock.withLock {
            try await db.transaction { tx -> (AuthResponse, Bool) in
                guard let ticket = try await SignupTicket.query(on: tx).filter(\.$ticketHash == ticketHash).first(),
                      let provider = ticket.provider
                else { throw AppError.signupTicketUnknown }
                guard ticket.expiresAt > Date() else { throw AppError.signupTicketExpired }

                // Signed up in the meantime, say on another device: sign in to that account instead.
                if let identity = try await ExternalIdentity.find(provider, subject: ticket.subject, on: tx) {
                    if identity.appleRefreshToken == nil, let refreshToken = ticket.appleRefreshToken {
                        identity.appleRefreshToken = refreshToken
                        try await identity.save(on: tx)
                    }
                    try await ticket.delete(on: tx)
                    let token = try await UserToken.startSession(for: identity.user, lifetime: lifetime, on: tx)
                    return (AuthResponse(token: token, account: try identity.user.account()), false)
                }

                let taken = try await User.query(on: tx)
                    .filter(\.$usernameKey == CredentialPolicy.normalized(username))
                    .first() != nil
                // The ticket stays valid, so the player can pick another name.
                guard !taken else { throw AppError.usernameTaken }

                let user = User(username: username, passwordHash: User.noPassword)
                try await user.save(on: tx)
                try await ExternalIdentity(
                    userID: try user.requireID(),
                    provider: provider,
                    subject: ticket.subject,
                    appleRefreshToken: ticket.appleRefreshToken
                ).save(on: tx)
                try await ticket.delete(on: tx)
                let token = try await UserToken.startSession(for: user, lifetime: lifetime, on: tx)
                return (AuthResponse(token: token, account: try user.account()), true)
            }
        }
        return try await response.encodeResponse(status: created ? .created : .ok, for: req)
    }

    /// A refresh token for `code`; `nil` if there's no code, no Sign in with Apple key, or Apple refused.
    private func exchange(_ code: String?, on req: Request) async -> String? {
        guard let code, !code.isEmpty, let appleTokens = services.appleTokens else { return nil }
        do {
            return try await appleTokens.refreshToken(forAuthorizationCode: code)
        } catch {
            req.logger.error("Could not exchange a Sign in with Apple authorization code: \(error)")
            return nil
        }
    }

    /// A free username that passes every check, like "Captain4821".
    private func suggestedUsername(on db: any Database) async throws -> String? {
        for attempt in 0..<10 {
            let number = attempt < 5 ? Int.random(in: 1_000...9_999) : Int.random(in: 100_000...999_999)
            let candidate = "\(Self.suggestionStems.randomElement() ?? "Captain")\(number)"
            guard (try? AuthController.validNewUsername(candidate, settings: services.settings)) != nil else { continue }
            let taken = try await User.query(on: db).filter(\.$usernameKey == CredentialPolicy.normalized(candidate)).first() != nil
            if !taken {
                return candidate
            }
        }
        return nil
    }
}
