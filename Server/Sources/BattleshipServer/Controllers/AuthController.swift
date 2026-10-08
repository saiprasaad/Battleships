import BattleshipAPI
import Fluent
import Vapor

/// Validates bearer tokens on protected routes.
struct BearerTokenAuthenticator: AsyncBearerAuthenticator {
    let services: AppServices

    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        guard let token = try await UserToken.query(on: request.db)
            .filter(\.$tokenHash == UserToken.hash(bearer.token))
            .with(\.$user)
            .first(),
            token.expiresAt > Date()
        else { return }
        await renewIfDue(token, on: request.db, logger: request.logger)
        request.auth.login(token.user)
        request.auth.login(token)
    }

    /// Sessions slide: one used in the second half of its life gets a full lifetime again, so people
    /// who keep playing stay signed in. That's one small write per session every few weeks.
    private func renewIfDue(_ token: UserToken, on db: any Database, logger: Logger) async {
        let lifetime = services.settings.sessionLifetime
        let now = Date()
        guard token.expiresAt.timeIntervalSince(now) < lifetime / 2, let tokenID = token.id else { return }
        let renewed = now.addingTimeInterval(lifetime)
        do {
            try await services.writeLock.withLock {
                try await UserToken.query(on: db)
                    .filter(\.$id == tokenID)
                    .filter(\.$expiresAt < renewed)
                    .set(\.$expiresAt, to: renewed)
                    .update()
            }
            token.expiresAt = renewed
        } catch {
            // The session is still valid; renewing can wait for the next request.
            logger.warning("Could not renew a session: \(error)")
        }
    }
}

struct AuthController: RouteCollection {
    let services: AppServices

    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        let limited = auth.grouped(RateLimitMiddleware(limiter: services.authRateLimiter, addressSource: services.settings.clientAddressSource))
        limited.post("register", use: register)
        limited.post("login", use: signIn)
        auth.grouped(BearerTokenAuthenticator(services: services), User.guardMiddleware(throwing: AppError.unauthorized))
            .post("logout", use: signOut)
    }

    @Sendable
    func register(req: Request) async throws -> Response {
        let credentials = try req.content.decode(Credentials.self)
        let username = try Self.validNewUsername(credentials.username, settings: services.settings)
        if let problem = CredentialPolicy.passwordProblem(credentials.password) {
            throw AppError(.badRequest, .invalidPassword, problem)
        }

        // Hash outside the write lock: bcrypt is deliberately slow.
        let passwordHash = try await services.passwords.hash(credentials.password)
        let db = req.db
        let lifetime = services.settings.sessionLifetime
        let response = try await services.writeLock.withLock {
            let taken = try await User.query(on: db)
                .filter(\.$usernameKey == CredentialPolicy.normalized(username))
                .first() != nil
            guard !taken else { throw AppError.usernameTaken }

            let user = User(username: username, passwordHash: passwordHash)
            try await user.save(on: db)
            let token = try await UserToken.startSession(for: user, lifetime: lifetime, on: db)
            return AuthResponse(token: token, account: try user.account())
        }
        return try await response.encodeResponse(status: .created, for: req)
    }

    @Sendable
    func signIn(req: Request) async throws -> AuthResponse {
        let credentials = try req.content.decode(Credentials.self)
        let key = CredentialPolicy.normalized(credentials.username.trimmingCharacters(in: .whitespacesAndNewlines))
        // Per username as well as per address, so guesses spread across many addresses still run out.
        guard await services.loginRateLimiter.consume(String(key.prefix(64))) else {
            throw AppError.tooManySignInAttempts
        }

        guard let user = try await User.query(on: req.db).filter(\.$usernameKey == key).first(), user.hasPassword else {
            // Burn the same time as a real check, so response timing doesn't reveal which usernames
            // exist, or which accounts sign in with Apple or Google and have no password.
            _ = try await services.passwords.verify(credentials.password, created: services.decoyPasswordHash)
            throw AppError.invalidCredentials
        }
        guard try await services.passwords.verify(credentials.password, created: user.passwordHash) else {
            throw AppError.invalidCredentials
        }

        let db = req.db
        let lifetime = services.settings.sessionLifetime
        let token = try await services.writeLock.withLock {
            try await UserToken.startSession(for: user, lifetime: lifetime, on: db)
        }
        return AuthResponse(token: token, account: try user.account())
    }

    @Sendable
    func signOut(req: Request) async throws -> HTTPStatus {
        if let token = req.auth.get(UserToken.self), let tokenID = token.id {
            let db = req.db
            try await services.writeLock.withLock {
                // The devices this session registered stop getting this player's notifications.
                try await Device.query(on: db).filter(\.$session.$id == tokenID).delete()
                try await token.delete(on: db)
            }
            await services.hub.disconnect(tokenID: tokenID)
        }
        req.auth.logout(UserToken.self)
        req.auth.logout(User.self)
        return .noContent
    }

    /// `username`, trimmed, if it's acceptable for a new account; the same rules for every way of
    /// signing up. Whether it's taken is checked when the account is created.
    static func validNewUsername(_ username: String, settings: ServerSettings) throws -> String {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = CredentialPolicy.usernameProblem(username) {
            throw AppError(.badRequest, .invalidUsername, problem)
        }
        if CredentialPolicy.isOffensiveOrReserved(username, extraWords: settings.extraBlockedUsernameWords) {
            throw AppError(.badRequest, .invalidUsername, "That username isn't allowed. Please choose another.")
        }
        return username
    }
}
