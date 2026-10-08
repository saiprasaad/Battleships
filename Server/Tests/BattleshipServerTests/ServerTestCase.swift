import BattleshipAPI
import BattleshipClient
import BattleshipCore
@testable import BattleshipServer
import FluentSQL
import XCTVapor
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Records push notifications instead of sending them.
actor RecordingPushService: PushService {
    private(set) var deliveries: [(message: PushMessage, targets: [PushTarget])] = []

    func send(_ message: PushMessage, to targets: [PushTarget]) async -> [String] {
        deliveries.append((message, targets))
        return []
    }

    var messages: [PushMessage] { deliveries.map(\.message) }
}

/// Boots a fresh app with an empty database for every test: in-memory SQLite, or the Postgres
/// database named by `TEST_DATABASE_URL` (which gets wiped).
class ServerTestCase: XCTestCase {
    var app: Application!
    var push: RecordingPushService!
    /// Signing keys for Sign in with Apple and Google, published by the tests.
    var keySets: TestKeySets!
    var appleTokens: RecordingAppleTokens!
    private var serverStarted = false
    private var openSockets: [SocketEvents] = []

    override func setUp() async throws {
        try await super.setUp()
        push = RecordingPushService()
        keySets = TestKeySets()
        appleTokens = RecordingAppleTokens()
        try await startApp()
    }

    override func tearDown() async throws {
        try await stopApp()
        app = nil
        try await super.tearDown()
    }

    private func startApp() async throws {
        app = try await Application.make(.testing)
        try await configure(app, pushService: push, keySets: keySets, appleTokens: appleTokens)
        if case .postgres = app.appServices.settings.database, let sql = app.db as? any SQLDatabase {
            // Every test shares the one Postgres database, so start from nothing.
            try await sql.raw("DROP SCHEMA public CASCADE").run()
            try await sql.raw("CREATE SCHEMA public").run()
            try await app.autoMigrate()
        }
    }

    private func stopApp() async throws {
        // The server waits for open connections before it stops.
        for socket in openSockets {
            await socket.close()
        }
        openSockets = []
        if serverStarted {
            await app.http.server.shared.shutdown()
            serverStarted = false
        }
        try await app.asyncShutdown()
    }

    /// Restarts the app, on an empty database, with `environment` set while it reads its settings.
    func restartApp(environment: [String: String]) async throws {
        try await stopApp()
        for (name, value) in environment {
            setenv(name, value, 1)
        }
        defer {
            for name in environment.keys {
                unsetenv(name)
            }
        }
        try await startApp()
    }

    /// Registers `username` through the API.
    @discardableResult
    func register(_ username: String, password: String = "correct horse battery") async throws -> (token: String, id: UUID) {
        var result: AuthResponse?
        try await app.testable().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(Credentials(username: username, password: password))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .created, res.body.string)
            result = try res.content.decode(AuthResponse.self)
        })
        let auth = try XCTUnwrap(result)
        return (auth.token, auth.account.id)
    }

    func bearer(_ token: String) -> HTTPHeaders {
        ["Authorization": "Bearer \(token)"]
    }

    /// Opens the realtime event stream as `client`'s session.
    func openEventSocket(for client: APIClient) async throws -> SocketEvents {
        let request = try XCTUnwrap(client.eventsRequest())
        let collector = SocketEvents()
        var headers = HTTPHeaders()
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers.add(name: name, value: value)
        }
        try await WebSocket.connect(
            to: try XCTUnwrap(request.url?.absoluteString),
            headers: headers,
            on: app.eventLoopGroup
        ) { socket in
            collector.attach(socket)
        }.get()
        openSockets.append(collector)
        return collector
    }

    /// Pretends the last move in a game happened `interval` earlier than it did.
    func backdateLastMove(of gameID: UUID, by interval: TimeInterval) async throws {
        let game = try await XCTUnwrapAsync(await GameRecord.find(gameID, on: app.db))
        let sql = try XCTUnwrap(app.db as? any SQLDatabase)
        // Straight to SQL: saving the model would stamp `updated_at` with the current time.
        try await sql.update(GameRecord.schema)
            .set("updated_at", to: game.lastActivity.addingTimeInterval(-interval))
            .where("id", .equal, gameID)
            .run()
    }

    /// Starts a real HTTP server on a free port, for tests that drive it with the app's own client.
    func startServer() async throws -> URL {
        try await app.http.server.shared.start(address: .hostname("127.0.0.1", port: 0))
        serverStarted = true
        let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func makeClient(_ baseURL: URL) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
    }

    /// Registers `username` and returns a signed-in client for them.
    func signedInClient(_ username: String, baseURL: URL) async throws -> APIClient {
        let client = makeClient(baseURL)
        let auth = try await client.register(Credentials(username: username, password: "correct horse battery"))
        client.token = auth.token
        return client
    }

    /// Waits until push notifications matching `predicate` have been recorded (they're sent in the background).
    func waitForPush(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping @Sendable (PushMessage) -> Bool
    ) async throws -> PushMessage {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = await push.messages.first(where: predicate) {
                return match
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for a push notification", file: file, line: line)
        throw CancellationError()
    }
}

/// Fleets with known positions so tests can aim precisely.
enum Fleets {
    /// Ships on rows A–E, all starting in column 1.
    static let topLeft: [ShipPlacement] = [
        ShipPlacement(kind: .carrier, origin: Coordinate("A1")!, orientation: .horizontal),
        ShipPlacement(kind: .battleship, origin: Coordinate("B1")!, orientation: .horizontal),
        ShipPlacement(kind: .cruiser, origin: Coordinate("C1")!, orientation: .horizontal),
        ShipPlacement(kind: .submarine, origin: Coordinate("D1")!, orientation: .horizontal),
        ShipPlacement(kind: .destroyer, origin: Coordinate("E1")!, orientation: .horizontal),
    ]

    /// Ships on rows F–J, all ending in column 10.
    static let bottomRight: [ShipPlacement] = [
        ShipPlacement(kind: .carrier, origin: Coordinate("J6")!, orientation: .horizontal),
        ShipPlacement(kind: .battleship, origin: Coordinate("I7")!, orientation: .horizontal),
        ShipPlacement(kind: .cruiser, origin: Coordinate("H8")!, orientation: .horizontal),
        ShipPlacement(kind: .submarine, origin: Coordinate("G8")!, orientation: .horizontal),
        ShipPlacement(kind: .destroyer, origin: Coordinate("F9")!, orientation: .horizontal),
    ]

    /// The nth cell of open water around `topLeft` (rows F–J are empty).
    static func missingTopLeft(_ index: Int) -> Coordinate {
        Coordinate(row: 5 + index / 10, column: index % 10)
    }
}

extension XCTestCase {
    /// Asserts that `operation` fails with the given API error code.
    func assertAPIError<T>(
        _ code: APIErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected error \(code.rawValue)", file: file, line: line)
        } catch let error as APIError {
            XCTAssertEqual(error.code, code, "\(error)", file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}

func XCTUnwrapAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
