import BattleshipAPI
import BattleshipClient
import BattleshipCore
@testable import BattleshipServer
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

/// Boots a fresh app with an empty in-memory database for every test.
class ServerTestCase: XCTestCase {
    var app: Application!
    var push: RecordingPushService!
    private var serverStarted = false

    override func setUp() async throws {
        try await super.setUp()
        app = try await Application.make(.testing)
        push = RecordingPushService()
        try await configure(app, pushService: push)
    }

    override func tearDown() async throws {
        if serverStarted {
            await app.http.server.shared.shutdown()
        }
        try await app.asyncShutdown()
        app = nil
        try await super.tearDown()
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
