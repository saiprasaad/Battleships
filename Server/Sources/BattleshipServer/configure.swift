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
    let authRateLimiter: RateLimiter
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

/// Configures the application. Tests pass their own push service to observe notifications.
func configure(_ app: Application, pushService: (any PushService)? = nil) async throws {
    let settings = try ServerSettings.load(for: app.environment)

    // JSON exactly as the app expects it (ISO 8601 dates).
    ContentConfiguration.global.use(encoder: APICoding.makeEncoder(), for: .json)
    ContentConfiguration.global.use(decoder: APICoding.makeDecoder(), for: .json)

    if let port = settings.port {
        app.http.server.configuration.port = port
    }

    switch settings.database {
    case let .postgres(url):
        try app.databases.use(.postgres(url: url), as: .psql)
    case let .sqliteFile(path):
        app.databases.use(.sqlite(.file(path)), as: .sqlite)
    case .sqliteInMemory:
        app.databases.use(.sqlite(.memory), as: .sqlite)
    }
    app.migrations.add(CreateUsers())
    app.migrations.add(CreateUserTokens())
    app.migrations.add(CreateGames())
    app.migrations.add(CreateDevices())
    try await app.autoMigrate()
    if case .sqliteFile = settings.database, let sql = app.db as? any SQLDatabase {
        // Write-ahead logging lets reads carry on while a write commits.
        try await sql.raw("PRAGMA journal_mode = WAL").run()
    }

    app.passwords.use(.bcrypt(cost: settings.bcryptCost))

    let push: any PushService
    if let pushService {
        push = pushService
    } else if let apns = settings.apns {
        await app.apns.configure(.jwt(
            privateKey: try .loadFrom(string: apns.privateKeyPEM),
            keyIdentifier: apns.keyID,
            teamIdentifier: apns.teamID
        ))
        push = APNSPushService(application: app, topic: apns.topic)
        app.logger.info("Push notifications enabled for \(apns.topic)")
    } else {
        push = DisabledPushService()
        app.logger.notice("Push notifications disabled: set APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC and APNS_PRIVATE_KEY to enable them")
    }

    let writeLock = AsyncLock()
    let hub = RealtimeHub(logger: app.logger)
    let notifier = Notifier(hub: hub, push: push, writeLock: writeLock, database: { [app] in app.db }, logger: app.logger)
    app.appServices = AppServices(
        settings: settings,
        writeLock: writeLock,
        hub: hub,
        games: GameService(settings: settings, writeLock: writeLock, notifier: notifier),
        authRateLimiter: RateLimiter(requestsPerMinute: settings.authRequestsPerMinute),
        decoyPasswordHash: try app.password.hash(UUID().uuidString)
    )

    app.middleware = Middlewares()
    app.middleware.use(RouteLoggingMiddleware(logLevel: .info))
    app.middleware.use(APIErrorMiddleware(environment: app.environment))

    try routes(app)
}

func routes(_ app: Application) throws {
    let services = app.appServices

    app.get("health") { _ in
        ["status": "ok"]
    }

    let v1 = app.grouped("v1")
    try v1.register(collection: AuthController(services: services))

    let signedIn = v1.grouped(BearerTokenAuthenticator(), User.guardMiddleware(throwing: AppError.unauthorized))
    try signedIn.register(collection: AccountController(services: services))
    try signedIn.register(collection: PlayersController())
    try signedIn.register(collection: GamesController(services: services))
    try signedIn.register(collection: DevicesController(services: services))
    try signedIn.register(collection: EventsController(services: services))
}
