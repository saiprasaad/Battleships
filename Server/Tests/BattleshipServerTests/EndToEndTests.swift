import BattleshipAPI
import BattleshipClient
import BattleshipCore
@testable import BattleshipServer
import XCTVapor
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Plays real games over HTTP and WebSocket using the same client SDK the iOS app ships with.
final class EndToEndTests: ServerTestCase {
    func testChallengeAndPlayAFullBattle() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("Bob", baseURL: baseURL)
        try await alice.registerDevice(DeviceRegistration(token: String(repeating: "a", count: 64), environment: .sandbox))
        try await bob.registerDevice(DeviceRegistration(token: String(repeating: "b", count: 64), environment: .production))

        // Alice challenges Bob, by username in any capitalisation.
        let challenge = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
        XCTAssertEqual(challenge.summary.status, .invited)
        XCTAssertEqual(challenge.summary.you, .one)
        XCTAssertEqual(challenge.summary.opponent?.username, "Bob")
        XCTAssertTrue(challenge.summary.isOutgoingChallenge)
        let invitation = try await waitForPush { $0.title == "New challenge" }
        XCTAssertEqual(invitation.body, "alice challenged you to a Classic battle.")

        // Bob sees the challenge but not Alice's fleet.
        let bobsLobby = try await bob.games()
        XCTAssertEqual(bobsLobby.map(\.id), [challenge.id])
        XCTAssertTrue(bobsLobby[0].isIncomingChallenge)
        let bobsView = try await bob.game(id: challenge.id)
        XCTAssertTrue(bobsView.yourFleet.isEmpty)
        XCTAssertTrue(bobsView.knownOpponentShips.isEmpty)

        // He can't fire before accepting, or accept with a broken fleet.
        await assertAPIError(.invalidGameState) { try await bob.fire(gameID: challenge.id, at: Coordinate("A1")!) }
        await assertAPIError(.invalidFleet) {
            try await bob.acceptChallenge(gameID: challenge.id, fleet: Array(Fleets.bottomRight.dropLast()))
        }

        let accepted = try await bob.acceptChallenge(gameID: challenge.id, fleet: Fleets.bottomRight)
        XCTAssertEqual(accepted.summary.status, .active)
        XCTAssertEqual(accepted.summary.turn, .one, "the challenger fires first")
        _ = try await waitForPush { $0.title == "Challenge accepted" }
        await assertAPIError(.notYourTurn) { try await bob.fire(gameID: challenge.id, at: Coordinate("A1")!) }

        // Alice sinks Bob's fleet; Bob only finds water.
        let targets = Fleets.bottomRight.flatMap(\.cells)
        var lastResponse: FireResponse?
        for (index, target) in targets.enumerated() {
            let response = try await alice.fire(gameID: challenge.id, at: target)
            XCTAssertTrue(response.move.result.isHit)
            lastResponse = response

            let sunkSoFar = response.game.knownOpponentShips
            XCTAssertTrue(sunkSoFar.allSatisfy { ship in ship.cells.allSatisfy(targets.prefix(index + 1).contains) },
                          "only sunk ships are revealed while the battle is on")
            if index < targets.count - 1 {
                XCTAssertNil(response.game.summary.outcome)
                let reply = try await bob.fire(gameID: challenge.id, at: Fleets.missingTopLeft(index))
                XCTAssertEqual(reply.move.result, .miss)
            }
        }

        let final = try XCTUnwrap(lastResponse)
        XCTAssertEqual(final.move.result, .sunk(.destroyer))
        XCTAssertEqual(final.game.summary.status, .finished)
        XCTAssertEqual(final.game.summary.outcome, Outcome(winner: .one, reason: .fleetDestroyed))
        XCTAssertEqual(final.game.summary.didWin, true)
        XCTAssertEqual(final.game.summary.opponentShipsRemaining, 0)
        XCTAssertEqual(final.game.perspective.myStats, ShotStats(shotsFired: 17, hits: 17))
        await assertAPIError(.gameOver) { try await alice.fire(gameID: challenge.id, at: Coordinate("J1")!) }

        // Bob gets to see where everything was once it's over.
        let bobsFinal = try await bob.game(id: challenge.id)
        XCTAssertEqual(Set(bobsFinal.knownOpponentShips), Set(Fleets.topLeft))
        XCTAssertEqual(bobsFinal.summary.didWin, false)
        let defeat = try await waitForPush { $0.title == "Defeat" }
        XCTAssertEqual(defeat.body, "alice sank your last ship.")
        let shotNews = await push.messages.filter { $0.title == "Your turn" }
        XCTAssertEqual(shotNews.count, 16 + 16, "every shot except the winning one tells the other player it's their turn")
        XCTAssertTrue(shotNews.contains { $0.body == "Bob fired at F1 and missed." })
        XCTAssertTrue(shotNews.contains { $0.body == "alice sank your Carrier!" })

        // Ratings move by the same amount in opposite directions.
        let aliceAccount = try await alice.account()
        let bobAccount = try await bob.account()
        XCTAssertEqual(aliceAccount.stats, PlayerStats(rating: 1016, wins: 1, losses: 0))
        XCTAssertEqual(bobAccount.stats, PlayerStats(rating: 984, wins: 0, losses: 1))

        let leaderboard = try await bob.leaderboard()
        XCTAssertEqual(leaderboard.map(\.player.username), ["alice", "Bob"])
        XCTAssertEqual(leaderboard.map(\.rank), [1, 2])
    }

    func testMatchmakingPairsPlayersLookingForTheSameMode() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)
        let carol = try await signedInClient("carol", baseURL: baseURL)
        try await alice.registerDevice(DeviceRegistration(token: String(repeating: "c", count: 64), environment: .sandbox))

        let waiting = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft))
        XCTAssertEqual(waiting.summary.status, .matchmaking)
        XCTAssertNil(waiting.summary.opponent)

        // Alice never gets matched with herself.
        let secondWait = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft))
        XCTAssertEqual(secondWait.summary.status, .matchmaking)

        // Carol wants a quick game, so she keeps waiting.
        let quick = try await carol.createGame(CreateGameRequest(mode: .quick, fleet: Rules.quick.randomFleet()))
        XCTAssertEqual(quick.summary.status, .matchmaking)

        // Bob joins the longest-waiting classic game.
        let matched = try await bob.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.bottomRight))
        XCTAssertEqual(matched.id, waiting.id)
        XCTAssertEqual(matched.summary.status, .active)
        XCTAssertEqual(matched.summary.you, .two)
        XCTAssertEqual(matched.summary.opponent?.username, "alice")
        XCTAssertFalse(matched.summary.isYourTurn)
        _ = try await waitForPush { $0.title == "Opponent found" && $0.body.contains("bob") }

        let alicesGames = try await alice.games()
        XCTAssertEqual(Set(alicesGames.map(\.id)), [waiting.id, secondWait.id])
        XCTAssertTrue(try XCTUnwrap(alicesGames.first { $0.id == waiting.id }).isYourTurn)

        // Waiting games can be withdrawn; games in progress can't.
        try await alice.cancelGame(gameID: secondWait.id)
        await assertAPIError(.invalidGameState) { try await alice.cancelGame(gameID: waiting.id) }
        let remaining = try await alice.games()
        XCTAssertEqual(remaining.map(\.id), [waiting.id])
    }

    func testRealtimeEventsReachTheOtherPlayer() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)

        // Without a valid session the upgrade is refused.
        let anonymous = makeClient(baseURL)
        anonymous.token = "bogus"
        await XCTAssertThrowsErrorAsync(try await openEventSocket(for: anonymous))

        let events = try await openEventSocket(for: bob)
        try await events.next { $0 == .hello }

        let invite = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
        let invited = try await events.next { event in
            if case let .gameUpdated(game) = event { return game.id == invite.id }
            return false
        }
        guard case let .gameUpdated(game) = invited else { return XCTFail("expected a game update") }
        XCTAssertTrue(game.summary.isIncomingChallenge)
        XCTAssertTrue(game.yourFleet.isEmpty, "Bob's view, not Alice's")

        _ = try await bob.acceptChallenge(gameID: invite.id, fleet: Fleets.bottomRight)
        _ = try await alice.fire(gameID: invite.id, at: Coordinate("J6")!)
        let shot = try await events.next { event in
            if case let .gameUpdated(game) = event { return game.moves.count == 1 }
            return false
        }
        guard case let .gameUpdated(afterShot) = shot else { return XCTFail("expected a game update") }
        XCTAssertEqual(afterShot.moves.first, Move(player: .one, target: Coordinate("J6")!, result: ShotResult.hit))
        XCTAssertTrue(afterShot.summary.isYourTurn)
        XCTAssertEqual(afterShot.perspective.homeMark(at: Coordinate("J6")!), .hit)

        // Withdrawing a challenge removes it from the other player's lobby.
        let second = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
        try await alice.cancelGame(gameID: second.id)
        try await events.next { $0 == .gameRemoved(gameID: second.id, reason: .cancelled) }

        // Signing out closes the socket that session opened.
        try await bob.signOut()
        try await events.waitUntilClosed()
    }

    /// The app's own realtime client, over URLSessionWebSocketTask. Linux's libcurl usually lacks
    /// WebSocket support, so this runs on macOS (CI covers it).
    func testAppRealtimeClientStaysConnected() async throws {
        #if canImport(Darwin)
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)

        let realtime = RealtimeClient(api: bob, session: URLSession(configuration: .ephemeral))
        let updates = UpdateCollector(realtime.updates())
        try await updates.next { $0 == RealtimeUpdate.connected }

        let invite = try await alice.createGame(CreateGameRequest(mode: .quick, fleet: Rules.quick.randomFleet(), opponent: "bob"))
        try await updates.next { update in
            if case let .event(.gameUpdated(game)) = update { return game.id == invite.id }
            return false
        }

        // When the session is revoked the client reports the drop and stops retrying.
        let unauthorized = expectation(description: "unauthorized handler runs")
        bob.setUnauthorizedHandler { unauthorized.fulfill() }
        try await bob.signOut()
        try await updates.next { $0 == RealtimeUpdate.disconnected }
        await fulfillment(of: [unauthorized], timeout: 10)
        updates.cancel()
        #else
        throw XCTSkip("URLSessionWebSocketTask needs a WebSocket-enabled libcurl on Linux; covered on macOS.")
        #endif
    }

    private func openEventSocket(for client: APIClient) async throws -> SocketEvents {
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
        return collector
    }

    func testDeletingAnAccountResignsItsBattles() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)
        let carol = try await signedInClient("carol", baseURL: baseURL)

        let battle = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
        _ = try await bob.acceptChallenge(gameID: battle.id, fleet: Fleets.bottomRight)
        let pendingChallenge = try await alice.createGame(CreateGameRequest(mode: .quick, fleet: Rules.quick.randomFleet(), opponent: "carol"))
        let carolsGames = try await carol.games()
        XCTAssertEqual(carolsGames.map(\.id), [pendingChallenge.id])

        try await alice.deleteAccount()

        // Bob wins the abandoned battle and keeps it in his history.
        let bobsGame = try await bob.game(id: battle.id)
        XCTAssertEqual(bobsGame.summary.status, .finished)
        XCTAssertEqual(bobsGame.summary.didWin, true)
        XCTAssertEqual(bobsGame.summary.outcome?.reason, .resignation)
        XCTAssertNil(bobsGame.summary.opponent)
        XCTAssertEqual(bobsGame.summary.opponentName, "Former player")
        let bobsAccount = try await bob.account()
        XCTAssertEqual(bobsAccount.stats.wins, 1)

        // Carol's pending challenge disappears.
        let carolsLobby = try await carol.games()
        XCTAssertEqual(carolsLobby, [])

        // Alice's session is gone, and her name is free again.
        await assertAPIError(.unauthorized) { try await alice.games() }
        let again = makeClient(baseURL)
        _ = try await again.register(Credentials(username: "alice", password: "a new password"))
    }

    func testSessionsAndCredentials() async throws {
        let baseURL = try await startServer()
        let client = makeClient(baseURL)

        await assertAPIError(.invalidUsername) {
            try await client.register(Credentials(username: "no spaces allowed", password: "long enough"))
        }
        await assertAPIError(.invalidPassword) {
            try await client.register(Credentials(username: "dave", password: "short"))
        }

        let registered = try await client.register(Credentials(username: "Dave_99", password: "long enough"))
        XCTAssertEqual(registered.account.username, "Dave_99")
        XCTAssertEqual(registered.account.stats, PlayerStats(rating: 1000, wins: 0, losses: 0))
        await assertAPIError(.usernameTaken) {
            try await client.register(Credentials(username: "dave_99", password: "another one"))
        }

        await assertAPIError(.invalidCredentials) {
            try await client.signIn(Credentials(username: "dave_99", password: "wrong password"))
        }
        await assertAPIError(.invalidCredentials) {
            try await client.signIn(Credentials(username: "nobody", password: "long enough"))
        }

        let session = try await client.signIn(Credentials(username: "DAVE_99", password: "long enough"))
        XCTAssertNotEqual(session.token, registered.token, "every sign-in gets its own session")
        client.token = session.token
        let account = try await client.account()
        XCTAssertEqual(account.username, "Dave_99")

        // Signing out revokes only that session.
        try await client.signOut()
        await assertAPIError(.unauthorized) { try await client.account() }
        client.token = registered.token
        let firstSession = try await client.account()
        XCTAssertEqual(firstSession.id, registered.account.id)
    }

    func testPlayerSearch() async throws {
        let baseURL = try await startServer()
        let me = try await signedInClient("captain", baseURL: baseURL)
        for name in ["Captain_Nemo", "captainHook", "capybara", "cap_n", "admiral"] {
            _ = try await signedInClient(name, baseURL: baseURL)
        }

        let captains = try await me.searchPlayers(prefix: "CAPTAIN")
        XCTAssertEqual(captains.map(\.username), ["Captain_Nemo", "captainHook"], "case-insensitive, and never yourself")
        // "_" is matched literally, not as a wildcard.
        let literalUnderscore = try await me.searchPlayers(prefix: "cap_")
        XCTAssertEqual(literalUnderscore.map(\.username), ["cap_n"])
        let injection = try await me.searchPlayers(prefix: "x%'")
        XCTAssertEqual(injection.count, 0)
        let empty = try await me.searchPlayers(prefix: "")
        XCTAssertEqual(empty.count, 0)
    }
}

/// Buffers a realtime stream so a test can wait for a particular update.
final class UpdateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [RealtimeUpdate] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<RealtimeUpdate>) {
        task = Task { [weak self] in
            for await update in stream {
                self?.append(update)
            }
        }
    }

    private func append(_ update: RealtimeUpdate) {
        lock.withLock { received.append(update) }
    }

    /// Waits for (and consumes) the first update matching `predicate`.
    @discardableResult
    func next(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping (RealtimeUpdate) -> Bool
    ) async throws -> RealtimeUpdate {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let match: RealtimeUpdate? = lock.withLock {
                guard let index = received.firstIndex(where: predicate) else { return nil }
                return received.remove(at: index)
            }
            if let match {
                return match
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for a realtime update", file: file, line: line)
        throw CancellationError()
    }

    func cancel() {
        task?.cancel()
    }
}

/// Collects events from a raw WebSocket connection to `/v1/events`.
final class SocketEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ServerEvent] = []
    private var closed = false

    func attach(_ socket: WebSocket) {
        socket.onText { [weak self] _, text in
            guard let event = try? APICoding.makeDecoder().decode(ServerEvent.self, from: Data(text.utf8)) else { return }
            self?.lock.withLock { self?.events.append(event) }
        }
        socket.onClose.whenComplete { [weak self] _ in
            self?.lock.withLock { self?.closed = true }
        }
    }

    @discardableResult
    func next(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping (ServerEvent) -> Bool
    ) async throws -> ServerEvent {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let match: ServerEvent? = lock.withLock {
                guard let index = events.firstIndex(where: predicate) else { return nil }
                return events.remove(at: index)
            }
            if let match {
                return match
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for a server event", file: file, line: line)
        throw CancellationError()
    }

    func waitUntilClosed(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ closed }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The socket stayed open", file: file, line: line)
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
