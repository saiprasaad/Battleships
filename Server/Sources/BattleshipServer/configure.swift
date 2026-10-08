import BattleshipAPI
import Fluent
import FluentPostgresDriver
import FluentSQL
import FluentSQLiteDriver
import Vapor
import VaporAPNS

/// Long-lived services shared by every request.
struct AppServices: Sendable {
    let settings: ServerSettings
    /// Serializes database writes; see ``AsyncLock``.
    let writeLock: AsyncLock
    let hub: RealtimeHub
    let games: GameService
    let passwords: PasswordHashing
    /// `nil` when Sign in with Apple isn't set up.
    let appleIdentity: (any IdentityTokenVerifying)?
    /// `nil` when Sign in with Google isn't set up.
    let googleIdentity: (any IdentityTokenVerifying)?
    /// Exchanges authorization codes and revokes tokens; `nil` without the Sign in with Apple key.
    let appleTokens: (any AppleTokenClient)?
    /// Sign-in and registration attempts per client address.
    let authRateLimiter: RateLimiter
    /// Sign-in attempts per username, wherever they come from.
    let loginRateLimiter: RateLimiter
    /// A real bcrypt hash, verified against when a username doesn't exist (see ``AuthController``).
    let decoyPasswordHash: String
}

extension Application {
    private struct AppServicesKey: StorageKey {
        typealias Value = AppServices
    }

    var appServices: AppServices {
        get {
            guard let services = storage[AppServicesKey.self] else { fatalError("configure(_:) has not run") }
            return services
        }
        set { storage[AppServicesKey.self] = newValue }
    }
}

/// Configures the application. Tests pass their own push service, signing-key source and Apple
/// token client, to run offline and see what would have been sent.
func configure(
    _ app: Application,
    pushService: (any PushService)? = nil,
    keySets: (any KeySetFetching)? = nil,
    appleTokens: (any AppleTokenClient)? = nil
) async throws {
    let settings = try ServerSettings.load(for: app.environment)

    // JSON exactly as the app expects it (ISO 8601 dates).
    ContentConfiguration.global.use(encoder: APICoding.makeEncoder(), for: .json)
    ContentConfiguration.global.use(decoder: APICoding.makeDecoder(), for: .json)

    if let port = settings.port {
        app.http.server.configuration.port = port
    }

    switch settings.database {
    case let .postgres(url):
        do {
            try app.databases.use(.postgres(url: url), as: .psql)
        } catch {
            // Not the URL itself, nor the error describing it: it holds the database password.
            throw ConfigurationError("DATABASE_URL isn't a usable postgres:// URL. It should look like postgres://user:password@host:5432/database.")
        }
    case let .sqliteFile(path):
        app.databases.use(.sqlite(.file(path)), as: .sqlite)
    case .sqliteInMemory:
        app.databases.use(.sqlite(.memory), as: .sqlite)
    }
    app.migrations.add(CreateUsers())
    app.migrations.add(CreateUserTokens())
    app.migrations.add(CreateGames())
    app.migrations.add(CreateDevices())
    app.migrations.add(CreateBlocks())
    app.migrations.add(CreateReports())
    app.migrations.add(AddDeviceSessions())
    app.migrations.add(AddLookupIndexes())
    app.migrations.add(CreateExternalIdentities())
    app.migrations.add(CreateSignupTickets())
    try await app.autoMigrate()
    if case .sqliteFile = settings.database, let sql = app.db as? any SQLDatabase {
        // Write-ahead logging lets reads carry on while a write commits.
        try await sql.raw("PRAGMA journal_mode = WAL").run()
    }

    app.passwords.use(.bcrypt(cost: settings.bcryptCost))
    // At most half the cores, so a flood of sign-ins leaves the rest for everything else.
    let passwords = PasswordHashing(
        hasher: app.password.sync,
        threads: max(1, min(4, System.coreCount / 2)),
        maxPending: 32
    )
    app.lifecycle.use(passwords)

    let push: any PushService
    if let pushService {
        push = pushService
    } else if let apns = settings.apns {
        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try .loadFrom(string: apns.privateKeyPEM)
        } catch {
            throw ConfigurationError("APNS_PRIVATE_KEY (or the file at APNS_PRIVATE_KEY_PATH) must be the contents of an APNs .p8 key.")
        }
        await app.apns.configure(.jwt(privateKey: privateKey, keyIdentifier: apns.keyID, teamIdentifier: apns.teamID))
        push = APNSPushService(application: app, topic: apns.topic)
        app.logger.info("Push notifications enabled for \(apns.topic)")
    } else {
        push = DisabledPushService()
        app.logger.notice("Push notifications disabled: set APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC and APNS_PRIVATE_KEY to enable them")
    }

    let keySets = keySets ?? HTTPKeySetFetcher(client: app.client)
    let appleIdentity = settings.appleSignIn.map {
        JWKSIdentityTokenVerifier(.apple(bundleID: $0.bundleID), fetcher: keySets, logger: app.logger)
    }
    let googleIdentity = settings.googleClientID.map {
        JWKSIdentityTokenVerifier(.google(clientID: $0), fetcher: keySets, logger: app.logger)
    }
    let appleTokenClient: (any AppleTokenClient)?
    if let apple = settings.appleSignIn, let key = apple.key {
        if let appleTokens {
            appleTokenClient = appleTokens
        } else {
            appleTokenClient = try await AppleTokenService(bundleID: apple.bundleID, key: key, post: AppleTokenService.poster(using: app.client))
        }
    } else {
        appleTokenClient = nil
    }

    let writeLock = AsyncLock()
    let hub = RealtimeHub(logger: app.logger)
    let notifier = Notifier(
        presenter: GamePresenter(turnTimeLimit: settings.turnTimeLimit),
        hub: hub,
        push: push,
        writeLock: writeLock,
        database: { [app] in app.db },
        logger: app.logger
    )
    app.appServices = AppServices(
        settings: settings,
        writeLock: writeLock,
        hub: hub,
        games: GameService(
            settings: settings,
            writeLock: writeLock,
            notifier: notifier,
            newGameLimiter: RateLimiter(limit: settings.newGamesPerHour, per: 60 * 60),
            appleTokens: appleTokenClient
        ),
        passwords: passwords,
        appleIdentity: appleIdentity,
        googleIdentity: googleIdentity,
        appleTokens: appleTokenClient,
        authRateLimiter: RateLimiter(requestsPerMinute: settings.authRequestsPerMinute),
        loginRateLimiter: RateLimiter(limit: settings.loginAttemptsPerUsernamePerHour, per: 60 * 60),
        decoyPasswordHash: try app.password.hash(UUID().uuidString)
    )

    if settings.supportEmail == nil, app.environment == .production {
        app.logger.warning("SUPPORT_EMAIL isn't set. The privacy policy and support pages need a contact address before you submit to the App Store.")
    }
    if let apple = settings.appleSignIn, apple.key == nil, app.environment == .production {
        app.logger.error("Sign in with Apple is on without its key (APPLE_TEAM_ID, APPLE_SIGN_IN_KEY_ID, APPLE_SIGN_IN_PRIVATE_KEY), so deleting an account can't revoke the app's access to the player's Apple ID. App Review requires that.")
    }
    if settings.googleClientID != nil, settings.appleSignIn == nil {
        app.logger.warning("Sign in with Google is on but Sign in with Apple isn't. App Store guideline 4.8 requires offering Sign in with Apple alongside it.")
    }

    app.middleware = Middlewares()
    app.middleware.use(RequestLoggingMiddleware(logLevel: .info))
    app.middleware.use(APIErrorMiddleware(environment: app.environment))

    try routes(app)
}

func routes(_ app: Application) throws {
    let services = app.appServices

    try app.register(collection: HealthController(services: services))
    try app.register(collection: SiteController(settings: services.settings))

    let v1 = app.grouped("v1")
    try v1.register(collection: AuthController(services: services))
    try v1.register(collection: ExternalSignInController(services: services))
    if let token = services.settings.adminToken {
        try v1.register(collection: AdminController(services: services, token: token))
    }

    let signedIn = v1.grouped(BearerTokenAuthenticator(services: services), User.guardMiddleware(throwing: AppError.unauthorized))
    try signedIn.register(collection: AccountController(services: services))
    try signedIn.register(collection: PlayersController())
    try signedIn.register(collection: GamesController(services: services))
    try signedIn.register(collection: DevicesController(services: services))
    try signedIn.register(collection: EventsController(services: services))
    try signedIn.register(collection: ModerationController(services: services))
}

