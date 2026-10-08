import BattleshipAPI
import Fluent
import Vapor

/// Validates bearer tokens on protected routes.
struct BearerTokenAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        guard let token = try await UserToken.query(on: request.db)
            .filter(\.$tokenHash == UserToken.hash(bearer.token))
            .with(\.$user)
            .first(),
            token.expiresAt > Date()
        else { return }
        request.auth.login(token.user)
        request.auth.login(token)
    }
}

struct AuthController: RouteCollection {
    let services: AppServices

    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        let limited = auth.grouped(RateLimitMiddleware(limiter: services.authRateLimiter))
        limited.post("register", use: register)
        limited.post("login", use: signIn)
        auth.grouped(BearerTokenAuthenticator(), User.guardMiddleware(throwing: AppError.unauthorized)).post("logout", use: signOut)
    }

    @Sendable
    func register(req: Request) async throws -> Response {
        let credentials = try req.content.decode(Credentials.self)
        let username = credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = CredentialPolicy.usernameProblem(username) {
            throw AppError(.badRequest, .invalidUsername, problem)
        }
        if let problem = CredentialPolicy.passwordProblem(credentials.password) {
            throw AppError(.badRequest, .invalidPassword, problem)
        }

        // Hash outside the write lock: bcrypt is deliberately slow.
        let passwordHash = try await req.password.async.hash(credentials.password)
        let db = req.db
        let lifetime = services.settings.sessionLifetime
        let response = try await services.writeLock.withLock {
            let taken = try await User.query(on: db)
                .filter(\.$usernameKey == CredentialPolicy.normalized(username))
                .first() != nil
            guard !taken else { throw AppError.usernameTaken }

            let user = User(username: username, passwordHash: passwordHash)
            try await user.save(on: db)
            let token = try await Self.startSession(for: user, lifetime: lifetime, on: db)
            return AuthResponse(token: token, account: try user.account())
        }
        return try await response.encodeResponse(status: .created, for: req)
    }

    @Sendable
    func signIn(req: Request) async throws -> AuthResponse {
        let credentials = try req.content.decode(Credentials.self)
        let key = CredentialPolicy.normalized(credentials.username.trimmingCharacters(in: .whitespacesAndNewlines))

        guard let user = try await User.query(on: req.db).filter(\.$usernameKey == key).first() else {
            // Burn the same time as a real check so response timing doesn't reveal which usernames exist.
            _ = try? await req.password.async.verify(credentials.password, created: services.decoyPasswordHash)
            throw AppError.invalidCredentials
        }
        guard try await req.password.async.verify(credentials.password, created: user.passwordHash) else {
            throw AppError.invalidCredentials
        }

        let db = req.db
        let lifetime = services.settings.sessionLifetime
        let userID = try user.requireID()
        let token = try await services.writeLock.withLock {
            // Tidy up this player's expired sessions while we're here.
            try await UserToken.query(on: db)
                .filter(\.$user.$id == userID)
                .filter(\.$expiresAt < Date())
                .delete()
            return try await Self.startSession(for: user, lifetime: lifetime, on: db)
        }
        return AuthResponse(token: token, account: try user.account())
    }

    @Sendable
    func signOut(req: Request) async throws -> HTTPStatus {
        if let token = req.auth.get(UserToken.self), let tokenID = token.id {
            let db = req.db
            try await services.writeLock.withLock {
                try await token.delete(on: db)
            }
            await services.hub.disconnect(tokenID: tokenID)
        }
        req.auth.logout(UserToken.self)
        req.auth.logout(User.self)
        return .noContent
    }

    private static func startSession(for user: User, lifetime: TimeInterval, on db: any Database) async throws -> String {
        let (token, hash) = UserToken.generate()
        let record = UserToken(userID: try user.requireID(), tokenHash: hash, expiresAt: Date().addingTimeInterval(lifetime))
        try await record.save(on: db)
        return token
    }
}
