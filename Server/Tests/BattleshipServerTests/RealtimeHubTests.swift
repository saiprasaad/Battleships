import BattleshipAPI
import BattleshipClient
import BattleshipCore
@testable import BattleshipServer
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTVapor

/// The realtime event stream under misbehaving clients.
final class RealtimeHubTests: ServerTestCase {
    /// A client that stops reading must not hold anything up: its events queue without being waited
    /// for, moves that concern it still go through, and once too much is queued it's cut off.
    func testAClientThatStopsReadingIsCutOffWithoutStallingWrites() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)
        let bobID = try await bob.account().id
        let hub = app.appServices.hub
        let stalled = try await NonReadingClient.connect(
            port: try XCTUnwrap(baseURL.port),
            token: try XCTUnwrap(bob.token),
            group: app.eventLoopGroup
        )
        defer { stalled.channel.close(promise: nil) }
        try await waitUntil { await hub.connectionCount(for: bobID) == 1 }

        // A lot happens while Bob's phone isn't reading. Once the socket buffers are full his events
        // start to back up, but sending them never waits for him.
        let bulky = ServerEvent.gameUpdated(.bulky)
        try await withTimeout(.seconds(10)) {
            var sent = 0
            while await hub.unacknowledgedWrites(for: bobID) < 8, sent < 200 {
                await hub.send(bulky, to: bobID)
                sent += 1
            }
        }
        let backlog = await hub.unacknowledgedWrites(for: bobID)
        XCTAssertGreaterThanOrEqual(backlog, 8)
        XCTAssertLessThanOrEqual(backlog, RealtimeHub.maxUnacknowledgedWrites)

        // Meanwhile games go on, including ones whose news has to be sent to him.
        try await withTimeout(.seconds(5)) {
            let game = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
            _ = try await bob.acceptChallenge(gameID: game.id, fleet: Fleets.bottomRight)
            _ = try await alice.fire(gameID: game.id, at: Coordinate("A1")!)
        }

        // When too much is waiting he's cut off: the connection is closed outright, since a polite
        // close frame would wait behind everything he hasn't read.
        try await withTimeout(.seconds(10)) {
            var sent = 0
            while await hub.connectionCount(for: bobID) > 0, sent < 200 {
                await hub.send(bulky, to: bobID)
                sent += 1
            }
        }
        let remaining = await hub.connectionCount(for: bobID)
        XCTAssertEqual(remaining, 0)
        // When Bob's phone reads again, it finds the connection gone. It has to read through what's
        // already in its buffer first: Linux throws that away on a reset, but macOS delivers it.
        try await stalled.channel.setOption(ChannelOptions.autoRead, value: true).get()
        try await withTimeout(.seconds(10)) { try await stalled.channel.closeFuture.get() }
    }

    func testEachPlayerKeepsAtMostFiveConnections() async throws {
        let baseURL = try await startServer()
        let bob = try await signedInClient("bob", baseURL: baseURL)
        let bobID = try await bob.account().id
        var sockets: [SocketEvents] = []
        for _ in 0...RealtimeHub.maxConnectionsPerPlayer {
            let events = try await openEventSocket(for: bob)
            try await events.next { $0 == .hello }
            sockets.append(events)
        }

        // The oldest made way for the newest.
        try await sockets[0].waitUntilClosed()
        let open = await app.appServices.hub.connectionCount(for: bobID)
        XCTAssertEqual(open, RealtimeHub.maxConnectionsPerPlayer)
        for socket in sockets.dropFirst() {
            XCTAssertFalse(socket.isClosed)
        }
    }

    func testSigningOutClosesOnlyThatSessionsConnections() async throws {
        let baseURL = try await startServer()
        let phone = try await signedInClient("bob", baseURL: baseURL)
        let tablet = makeClient(baseURL)
        tablet.token = try await tablet.signIn(Credentials(username: "bob", password: "correct horse battery")).token
        let phoneEvents = try await openEventSocket(for: phone)
        let tabletEvents = try await openEventSocket(for: tablet)
        try await phoneEvents.next { $0 == .hello }
        try await tabletEvents.next { $0 == .hello }

        try await phone.signOut()
        try await phoneEvents.waitUntilClosed()
        XCTAssertFalse(tabletEvents.isClosed)
    }
}

/// Opens the event stream and then never reads another byte, like a phone that has stalled.
final class NonReadingClient: Sendable {
    let channel: any Channel

    private init(channel: any Channel) {
        self.channel = channel
    }

    static func connect(port: Int, token: String, group: any EventLoopGroup) async throws -> NonReadingClient {
        let channel = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 2048)
            .connect(host: "127.0.0.1", port: port)
            .get()
        let handshake = """
        GET /v1/events HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        Sec-WebSocket-Version: 13\r
        Authorization: Bearer \(token)\r
        \r

        """
        try await channel.writeAndFlush(ByteBuffer(string: handshake))
        return NonReadingClient(channel: channel)
    }
}

extension GameDetail {
    /// A game with a very long move list: about 200 KB of JSON.
    static let bulky: GameDetail = {
        let summary = GameSummary(
            id: UUID(), mode: .classic, status: .active, you: .two, opponent: nil, turn: .two, outcome: nil,
            yourShipsRemaining: 5, opponentShipsRemaining: 5, createdAt: Date(), updatedAt: Date()
        )
        let moves = Array(repeating: Move(player: .one, target: Coordinate("J10")!, result: .miss), count: 5_000)
        return GameDetail(summary: summary, yourFleet: Fleets.bottomRight, knownOpponentShips: [], moves: moves)
    }()
}

struct TimeoutError: Error, CustomStringConvertible {
    let limit: Duration
    var description: String { "Didn't finish within \(limit)" }
}

/// Runs `operation`, failing if it hasn't finished within `limit`. Doesn't wait for a stuck
/// operation to give up, so a hang fails the test instead of freezing it.
@discardableResult
func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let finished = NIOLockedValueBox(false)
        let finish: @Sendable (Result<T, any Error>) -> Void = { result in
            let first = finished.withLockedValue { done in
                defer { done = true }
                return !done
            }
            if first {
                continuation.resume(with: result)
            }
        }
        let timer = Task {
            try await Task.sleep(for: limit)
            finish(.failure(TimeoutError(limit: limit)))
        }
        Task {
            do {
                finish(.success(try await operation()))
            } catch {
                finish(.failure(error))
            }
            timer.cancel()
        }
    }
}

/// Polls `condition` until it holds, failing after `timeout`.
func waitUntil(
    timeout: Duration = .seconds(5),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @Sendable () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for a condition", file: file, line: line)
    throw TimeoutError(limit: timeout)
}
