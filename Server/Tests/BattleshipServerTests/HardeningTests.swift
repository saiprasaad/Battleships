import BattleshipAPI
import BattleshipClient
import BattleshipCore
@testable import BattleshipServer
import FluentSQL
import FluentSQLiteDriver
import NIOConcurrencyHelpers
import NIOCore
import XCTVapor
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abuse and robustness: rate limits, caps, sessions, devices, matchmaking and storage.
final class HardeningTests: ServerTestCase {
    // MARK: Challenges

    func testOnlyOneUnansweredChallengeBetweenTwoPlayers() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)
        let carol = try await signedInClient("carol", baseURL: baseURL)
        try await bob.registerDevice(DeviceRegistration(token: String(repeating: "b", count: 64), environment: .production))

        let first = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
        await assertAPIError(.invalidGameState, message: "You've already challenged bob") {
            try await alice.createGame(CreateGameRequest(mode: .quick, fleet: Rules.quick.randomFleet(), opponent: "Bob"))
        }
        await assertAPIError(.invalidGameState, message: "alice has already challenged you") {
            try await bob.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "alice"))
        }
        _ = try await carol.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
        _ = try await waitForPush { $0.body.hasPrefix("alice challenged you") }
        _ = try await waitForPush { $0.body.hasPrefix("carol challenged you") }
        let challengesForBob = await push.messages.filter { $0.title == "New challenge" }.map(\.body)
        XCTAssertEqual(challengesForBob.count, 2, "refused challenges send no notification: \(challengesForBob)")

        // Once it's answered, another can follow.
        _ = try await bob.acceptChallenge(gameID: first.id, fleet: Fleets.bottomRight)
        let second = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
        try await bob.declineChallenge(gameID: second.id)
        _ = try await bob.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "alice"))
    }

    func testPlayersCanOnlyHaveSoManyChallengesWaiting() async throws {
        try await restartApp(environment: ["MAX_PENDING_CHALLENGES": "2"])
        let baseURL = try await startServer()
        let dave = try await signedInClient("dave", baseURL: baseURL)
        var challengers: [APIClient] = []
        for name in ["ann", "ben", "cat"] {
            challengers.append(try await signedInClient(name, baseURL: baseURL))
        }

        let first = try await challengers[0].createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "dave"))
        _ = try await challengers[1].createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "dave"))
        await assertAPIError(.tooManyGames, message: "dave has too many challenges waiting") {
            try await challengers[2].createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "dave"))
        }

        try await dave.declineChallenge(gameID: first.id)
        _ = try await challengers[2].createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "dave"))
    }

    func testStartingGamesIsRateLimitedPerPlayer() async throws {
        try await restartApp(environment: ["NEW_GAME_RATE_LIMIT_PER_HOUR": "2"])
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)

        _ = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft))
        _ = try await alice.createGame(CreateGameRequest(mode: .quick, fleet: Rules.quick.randomFleet()))
        await assertAPIError(.rateLimited) {
            try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
        }
        // Per player: Bob isn't affected.
        _ = try await bob.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.bottomRight, opponent: "alice"))
    }

    // MARK: Matchmaking

    func testMatchmakingSkipsPlayersWhoQueuedLongAgoAndLeft() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)
        let carol = try await signedInClient("carol", baseURL: baseURL)
        let aliceID = try await alice.account().id

        // Alice queued an hour ago and hasn't been online since.
        let alicesWait = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft))
        try await backdateCreation(of: alicesWait.id, by: 3600)

        let bobsGame = try await bob.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.bottomRight))
        XCTAssertEqual(bobsGame.summary.status, .matchmaking, "Bob isn't paired with someone who's probably gone")
        XCTAssertNotEqual(bobsGame.id, alicesWait.id)

        // Alice comes back: her game is the longest waiting again, and Carol gets it.
        let events = try await openEventSocket(for: alice)
        try await events.next { $0 == .hello }
        let carolsGame = try await carol.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.bottomRight))
        XCTAssertEqual(carolsGame.id, alicesWait.id)
        XCTAssertEqual(carolsGame.summary.status, .active)

        // Having been online in the last few minutes counts too.
        await events.close()
        let hub = app.appServices.hub
        try await waitUntil { await hub.connectionCount(for: aliceID) == 0 }
        let alicesNext = try await alice.createGame(CreateGameRequest(mode: .quick, fleet: Rules.quick.randomFleet()))
        try await backdateCreation(of: alicesNext.id, by: 3600)
        let bobsQuick = try await bob.createGame(CreateGameRequest(mode: .quick, fleet: Rules.quick.randomFleet()))
        XCTAssertEqual(bobsQuick.id, alicesNext.id)
    }

    // MARK: Ratings

    func testBattlesThatEndBeforeBothPlayersFireAreUnrated() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)
        let fresh = PlayerStats(rating: 1000, wins: 0, losses: 0)

        // Resigning straight away.
        let resigned = try await startBattle(alice, versus: bob)
        let result = try await alice.resign(gameID: resigned)
        XCTAssertEqual(result.summary.outcome, Outcome(winner: .two, reason: .resignation))

        // Resigning after one shot, before the other side has fired.
        let oneShot = try await startBattle(alice, versus: bob)
        _ = try await alice.fire(gameID: oneShot, at: Coordinate("A1")!)
        _ = try await alice.resign(gameID: oneShot)

        // Winning on time against a player who never fired.
        let noShow = try await startBattle(alice, versus: bob)
        try await backdateLastMove(of: noShow, by: 72 * 3600 + 1)
        let claimed = try await bob.claimVictory(gameID: noShow)
        XCTAssertEqual(claimed.summary.status, .finished)

        let aliceStats = try await alice.account().stats
        let bobStats = try await bob.account().stats
        XCTAssertEqual(aliceStats, fresh)
        XCTAssertEqual(bobStats, fresh)
        let leaderboard = try await alice.leaderboard()
        XCTAssertEqual(leaderboard, [])

        // Once both have fired, it counts.
        let real = try await startBattle(alice, versus: bob)
        _ = try await alice.fire(gameID: real, at: Coordinate("A1")!)
        _ = try await bob.fire(gameID: real, at: Coordinate("J1")!)
        _ = try await alice.resign(gameID: real)
        let aliceAfter = try await alice.account().stats
        let bobAfter = try await bob.account().stats
        XCTAssertEqual(aliceAfter, PlayerStats(rating: 984, wins: 0, losses: 1))
        XCTAssertEqual(bobAfter, PlayerStats(rating: 1016, wins: 1, losses: 0))
    }

    /// Alice challenges Bob and he accepts; Alice moves first.
    private func startBattle(_ alice: APIClient, versus bob: APIClient) async throws -> UUID {
        let game = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
        _ = try await bob.acceptChallenge(gameID: game.id, fleet: Fleets.bottomRight)
        return game.id
    }

    // MARK: Signing in

    func testForwardedForHeadersDontBypassTheSignInLimit() async throws {
        try await restartApp(environment: ["AUTH_RATE_LIMIT_PER_MINUTE": "2"])
        let statuses = try await signInStatuses(forwardedFor: ["1.1.1.1", "2.2.2.2", "3.3.3.3"])
        XCTAssertEqual(statuses, [.unauthorized, .unauthorized, .tooManyRequests])
    }

    func testTrustedProxiesAddressesAreUsedForTheSignInLimit() async throws {
        try await restartApp(environment: ["AUTH_RATE_LIMIT_PER_MINUTE": "1", "TRUSTED_PROXY_COUNT": "1"])
        // The proxy appends the real address, so whatever the client wrote before it doesn't matter.
        let statuses = try await signInStatuses(forwardedFor: ["6.6.6.6, 1.1.1.1", "6.6.6.6, 2.2.2.2", "7.7.7.7, 1.1.1.1"])
        XCTAssertEqual(statuses, [.unauthorized, .unauthorized, .tooManyRequests])
    }

    func testClientAddressSources() throws {
        func request(_ headers: [(String, String)]) throws -> Request {
            Request(
                application: app,
                method: .GET,
                url: "/",
                headers: HTTPHeaders(headers),
                remoteAddress: try SocketAddress(ipAddress: "10.0.0.1", port: 4321),
                on: app.eventLoopGroup.next()
            )
        }
        let spoofed = try request([("X-Forwarded-For", "6.6.6.6")])
        XCTAssertEqual(spoofed.clientAddress(from: .peer), "10.0.0.1")
        XCTAssertEqual(spoofed.clientAddress(from: .header("Fly-Client-IP")), "10.0.0.1", "falls back to the peer")

        let proxied = try request([("X-Forwarded-For", "6.6.6.6, 3.3.3.3"), ("X-Forwarded-For", "2.2.2.2"), ("Fly-Client-IP", "4.4.4.4")])
        XCTAssertEqual(proxied.clientAddress(from: .forwardedFor(trustedProxies: 1)), "2.2.2.2")
        XCTAssertEqual(proxied.clientAddress(from: .forwardedFor(trustedProxies: 2)), "3.3.3.3")
        XCTAssertEqual(proxied.clientAddress(from: .forwardedFor(trustedProxies: 5)), "6.6.6.6", "never beyond the first entry")
        XCTAssertEqual(proxied.clientAddress(from: .header("Fly-Client-IP")), "4.4.4.4")
        XCTAssertEqual(try request([]).clientAddress(from: .forwardedFor(trustedProxies: 1)), "10.0.0.1")
    }

    func testSignInAttemptsAreLimitedPerUsername() async throws {
        try await restartApp(environment: ["LOGIN_RATE_LIMIT_PER_USERNAME_PER_HOUR": "3", "TRUSTED_PROXY_COUNT": "1"])
        try await register("alice", password: "correct horse battery")
        try await register("bob", password: "correct horse battery")

        // Wrong guesses from three different addresses, then the right password from a fourth.
        var statuses: [HTTPStatus] = []
        for (index, password) in ["guess one", "guess two", "guess three", "correct horse battery"].enumerated() {
            statuses.append(try await signInStatus("ALICE", password: password, forwardedFor: "9.9.9.\(index)"))
        }
        XCTAssertEqual(statuses, [.unauthorized, .unauthorized, .unauthorized, .tooManyRequests])
        let bobsStatus = try await signInStatus("bob", password: "correct horse battery", forwardedFor: "9.9.9.9")
        XCTAssertEqual(bobsStatus, .ok)
    }

    private func signInStatuses(forwardedFor addresses: [String]) async throws -> [HTTPStatus] {
        var statuses: [HTTPStatus] = []
        for address in addresses {
            statuses.append(try await signInStatus("nobody", password: "whatever123", forwardedFor: address))
        }
        return statuses
    }

    private func signInStatus(_ username: String, password: String, forwardedFor address: String) async throws -> HTTPStatus {
        var status: HTTPStatus?
        try await app.testable().test(.POST, "v1/auth/login", headers: ["X-Forwarded-For": address], beforeRequest: { req in
            try req.content.encode(Credentials(username: username, password: password))
        }, afterResponse: { res async in
            status = res.status
        })
        return try XCTUnwrap(status)
    }

    func testPasswordHashingTurnsAwayWorkBeyondItsQueue() async throws {
        let gate = DispatchSemaphore(value: 0)
        let hashing = PasswordHashing(hasher: GatedHasher(gate: gate), threads: 1, maxPending: 2)
        let first = Task { try await hashing.verify("one", created: "x") }
        let second = Task { try await hashing.verify("two", created: "x") }
        try await waitUntil { hashing.pendingCount == 2 }

        do {
            _ = try await hashing.verify("three", created: "x")
            XCTFail("Expected the queue to be full")
        } catch let error as AppError {
            XCTAssertEqual(error, .serverBusy)
            XCTAssertEqual(error.status, .tooManyRequests)
        }

        gate.signal()
        gate.signal()
        let results = try await [first.value, second.value]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(hashing.pendingCount, 0)
        gate.signal()
        let fourth = try await hashing.verify("four", created: "x")
        XCTAssertTrue(fourth)
        try await hashing.shutdown()
    }

    func testRateLimiterMemoryIsBounded() async {
        let limiter = RateLimiter(limit: 1, per: 3600, maxKeys: 100)
        let start = Date()
        for index in 0..<1_000 {
            _ = await limiter.consume("client-\(index)", now: start.addingTimeInterval(Double(index)))
        }
        let tracked = await limiter.trackedKeys
        XCTAssertLessThanOrEqual(tracked, 100)
        // Recent keys are the ones kept.
        let recent = await limiter.consume("client-999", now: start.addingTimeInterval(1_000))
        XCTAssertFalse(recent)
    }

    // MARK: Sessions

    func testSessionsAreRenewedWhenUsedInTheSecondHalfOfTheirLife() async throws {
        let alice = try await register("alice")
        let lifetime = app.appServices.settings.sessionLifetime

        // Fresh sessions aren't touched.
        let fresh = try await token(alice.token).expiresAt
        try await app.testable().test(.GET, "v1/me", headers: bearer(alice.token)) { res async in
            XCTAssertEqual(res.status, .ok)
        }
        let untouched = try await token(alice.token).expiresAt
        XCTAssertEqual(untouched.timeIntervalSince1970, fresh.timeIntervalSince1970, accuracy: 0.001)

        // One with ten days left gets a full lifetime again.
        try await UserToken.query(on: app.db)
            .filter(\.$tokenHash == UserToken.hash(alice.token))
            .set(\.$expiresAt, to: Date().addingTimeInterval(10 * 86_400))
            .update()
        try await app.testable().test(.GET, "v1/me", headers: bearer(alice.token)) { res async in
            XCTAssertEqual(res.status, .ok)
        }
        let renewed = try await token(alice.token).expiresAt
        XCTAssertEqual(renewed.timeIntervalSinceNow, lifetime, accuracy: 60)
    }

    func testSigningInPurgesExpiredSessionsAndTheirDevices() async throws {
        let alice = try await register("alice")
        let bob = try await register("bob")
        try await registerDevice(String(repeating: "b", count: 64), token: bob.token)
        try await UserToken.query(on: app.db)
            .filter(\.$tokenHash == UserToken.hash(bob.token))
            .set(\.$expiresAt, to: Date().addingTimeInterval(-60))
            .update()

        let statusAfterExpiry = try await signInStatus("alice", password: "correct horse battery", forwardedFor: "1.2.3.4")
        XCTAssertEqual(statusAfterExpiry, .ok)
        let bobsSessions = try await UserToken.query(on: app.db).filter(\.$user.$id == bob.id).count()
        XCTAssertEqual(bobsSessions, 0, "everyone's expired sessions go, not just the signing-in player's")
        let devices = try await Device.query(on: app.db).count()
        XCTAssertEqual(devices, 0, "with the devices those sessions registered")
        let alicesSessions = try await UserToken.query(on: app.db).filter(\.$user.$id == alice.id).count()
        XCTAssertEqual(alicesSessions, 2)
    }

    private func token(_ bearerToken: String) async throws -> UserToken {
        try await XCTUnwrapAsync(await UserToken.query(on: app.db).filter(\.$tokenHash == UserToken.hash(bearerToken)).first())
    }

    // MARK: Devices

    func testEachPlayerKeepsTheirTenMostRecentlyRegisteredDevices() async throws {
        let alice = try await register("alice")
        let tokens = (0..<13).map { String(format: "%064x", $0 + 1) }
        for token in tokens.prefix(12) {
            try await registerDevice(token, token: alice.token)
        }
        var kept = try await Device.query(on: app.db).all().map(\.token)
        XCTAssertEqual(Set(kept), Set(tokens[2..<12]))

        // Registering again counts as recent: the third device survives the next one.
        try await registerDevice(tokens[2], token: alice.token)
        try await registerDevice(tokens[12], token: alice.token)
        kept = try await Device.query(on: app.db).all().map(\.token)
        XCTAssertEqual(Set(kept), Set([tokens[2]] + tokens[4..<13]))
    }

    func testDevicesFollowTheSessionThatRegisteredThem() async throws {
        let baseURL = try await startServer()
        let phone = try await signedInClient("alice", baseURL: baseURL)
        let tablet = makeClient(baseURL)
        tablet.token = try await tablet.signIn(Credentials(username: "alice", password: "correct horse battery")).token
        let carol = try await signedInClient("carol", baseURL: baseURL)
        let aliceID = try await phone.account().id
        let phoneToken = String(repeating: "a", count: 64), tabletToken = String(repeating: "c", count: 64)
        try await phone.registerDevice(DeviceRegistration(token: phoneToken, environment: .production))
        try await tablet.registerDevice(DeviceRegistration(token: tabletToken, environment: .production))
        var reachable = try await Notifier.signedInDevices(of: aliceID, on: app.db).map(\.token)
        XCTAssertEqual(Set(reachable), [phoneToken, tabletToken])

        // A device registered before sessions were recorded keeps getting notifications.
        let legacyToken = String(repeating: "d", count: 64)
        try await Device(userID: aliceID, sessionID: nil, token: legacyToken, environment: .production).save(on: app.db)

        // The tablet's session runs out: no more notifications there.
        try await UserToken.query(on: app.db)
            .filter(\.$tokenHash == UserToken.hash(try XCTUnwrap(tablet.token)))
            .set(\.$expiresAt, to: Date().addingTimeInterval(-60))
            .update()
        reachable = try await Notifier.signedInDevices(of: aliceID, on: app.db).map(\.token)
        XCTAssertEqual(Set(reachable), [phoneToken, legacyToken])
        _ = try await carol.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "alice"))
        _ = try await waitForPush { $0.title == "New challenge" }
        let targets = await push.deliveries.first?.targets.map(\.token)
        XCTAssertEqual(Set(targets ?? []), [phoneToken, legacyToken])

        // Signing out of the phone forgets the phone.
        try await phone.signOut()
        let phoneDevice = try await Device.query(on: app.db).filter(\.$token == phoneToken).first()
        XCTAssertNil(phoneDevice)

        // Someone else signs in on the tablet: it's theirs now, through their session.
        let bob = try await signedInClient("bob", baseURL: baseURL)
        try await bob.registerDevice(DeviceRegistration(token: tabletToken, environment: .production))
        let moved = try await XCTUnwrapAsync(await Device.query(on: app.db).filter(\.$token == tabletToken).first())
        let bobsID = try await bob.account().id
        XCTAssertEqual(moved.$user.id, bobsID)
        let bobsSession = try await token(try XCTUnwrap(bob.token))
        XCTAssertEqual(moved.$session.id, bobsSession.id)
    }

    func testDeviceTokensAreLeftOutOfTheRequestLog() {
        let token = String(repeating: "ab", count: 32)
        XCTAssertEqual(RequestLoggingMiddleware.loggablePath("/v1/devices/\(token)"), "/v1/devices/[redacted]")
        XCTAssertEqual(RequestLoggingMiddleware.loggablePath("/v1/devices/\(token)/"), "/v1/devices/[redacted]")
        XCTAssertEqual(RequestLoggingMiddleware.loggablePath("/v1/devices"), "/v1/devices")
        XCTAssertEqual(RequestLoggingMiddleware.loggablePath("/v1/games/42/shots"), "/v1/games/42/shots")
    }

    private func registerDevice(_ deviceToken: String, token: String) async throws {
        try await app.testable().test(.POST, "v1/devices", headers: bearer(token), beforeRequest: { req in
            try req.content.encode(DeviceRegistration(token: deviceToken, environment: .production))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .noContent)
        })
    }

    // MARK: Search

    func testSearchFindsLiteralUnderscoresAmongManyLookalikes() async throws {
        // Sixty names that "cap_" matches if "_" is a wildcard, all sorting before the real match.
        for index in 0..<60 {
            try await User(username: "cap\(index % 10)n\(index)", passwordHash: "x").save(on: app.db)
        }
        try await User(username: "cap_n", passwordHash: "x").save(on: app.db)
        let searcher = try await register("searcher")

        try await app.testable().test(.GET, "v1/players?prefix=cap_", headers: bearer(searcher.token)) { res async throws in
            XCTAssertEqual(try res.content.decode([PlayerSummary].self).map(\.username), ["cap_n"])
        }
        try await app.testable().test(.GET, "v1/players?prefix=CAP1", headers: bearer(searcher.token)) { res async throws in
            let names = try res.content.decode([PlayerSummary].self).map(\.username)
            XCTAssertEqual(names, ["cap1n1", "cap1n11", "cap1n21", "cap1n31", "cap1n41", "cap1n51"])
        }
    }

    // MARK: Health

    func testHealthCheckFailsWhenTheDatabaseDoesntAnswer() async throws {
        let healthy = try XCTUnwrap(app.db as? any SQLDatabase)
        let answered = await HealthController.databaseResponds(healthy, within: .seconds(2))
        XCTAssertTrue(answered)

        let start = ContinuousClock.now
        let stalled = await HealthController.databaseResponds(UnresponsiveDatabase(eventLoop: app.eventLoopGroup.next()), within: .milliseconds(200))
        XCTAssertFalse(stalled)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "doesn't wait for the query")
    }

    func testHealthCheckFailsWhileAWriteHoldsTheLockTooLong() async throws {
        let services = app.appServices
        let health = HealthController(services: services, maxWriteLockHold: .milliseconds(100))
        let released = NIOLockedValueBox(false)
        let holder = Task {
            try await services.writeLock.withLock {
                while !released.withLockedValue({ $0 }) {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
        }
        try await waitUntil { await services.writeLock.holdDuration() != nil }
        try await Task.sleep(for: .milliseconds(150))

        let request = Request(application: app, method: .GET, url: "/health", on: app.eventLoopGroup.next())
        let stuck = await health.check(req: request)
        XCTAssertEqual(stuck.status, .serviceUnavailable)
        XCTAssertEqual(stuck.body.string, #"{"status":"writes stalled"}"#)

        released.withLockedValue { $0 = true }
        try await holder.value
        let free = await services.writeLock.holdDuration()
        XCTAssertNil(free)
        let recovered = await health.check(req: request)
        XCTAssertEqual(recovered.status, .ok)
    }

    // MARK: Storage

    func testGamesAreStoredAsOneJSONDocumentPerColumn() async throws {
        let alice = try await register("alice")
        try await register("bob")
        try await app.testable().test(.POST, "v1/games", headers: bearer(alice.token), beforeRequest: { req in
            try req.content.encode(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .created)
        })

        let sql = try XCTUnwrap(app.db as? any SQLDatabase)
        if case .postgres = app.appServices.settings.database {
            let row = try await XCTUnwrapAsync(await sql.raw("SELECT jsonb_typeof(fleet_one) AS fleet, jsonb_typeof(moves) AS moves FROM games").first())
            XCTAssertEqual(try row.decode(column: "fleet", as: String.self), "array")
            XCTAssertEqual(try row.decode(column: "moves", as: String.self), "array")
        } else {
            // The same JSON text earlier versions stored for the bare arrays, so old databases read the same.
            let row = try await XCTUnwrapAsync(await sql.raw("SELECT fleet_one, moves FROM games").first())
            let fleet = try row.decode(column: "fleet_one", as: String.self)
            XCTAssertTrue(fleet.hasPrefix("[{"), fleet)
            XCTAssertEqual(try JSONDecoder().decode([ShipPlacement].self, from: Data(fleet.utf8)), Fleets.topLeft)
            XCTAssertEqual(try row.decode(column: "moves", as: String.self), "[]")
        }
    }

    func testGamesSavedByEarlierVersionsStillLoad() async throws {
        guard case .sqliteInMemory = app.appServices.settings.database else {
            throw XCTSkip("Only SQLite databases have games from before the JSON fix.")
        }
        let alice = try await register("alice")
        let bob = try await register("bob")
        let sql = try XCTUnwrap(app.db as? any SQLDatabase)
        let gameID = UUID()
        let move = Move(player: .one, target: Coordinate("J1")!, result: .miss)
        // As the earlier server wrote it: JSON text in each column.
        try await sql.insert(into: GameRecord.schema)
            .columns("id", "mode", "status", "player_one_id", "player_two_id", "fleet_one", "fleet_two", "moves", "turn", "created_at", "updated_at")
            .values(
                SQLBind(gameID), SQLBind(GameMode.classic.rawValue), SQLBind(GameStatus.active.rawValue), SQLBind(alice.id), SQLBind(bob.id),
                SQLBind(String(decoding: try JSONEncoder().encode(Fleets.topLeft), as: UTF8.self)),
                SQLBind(String(decoding: try JSONEncoder().encode(Fleets.bottomRight), as: UTF8.self)),
                SQLBind(String(decoding: try JSONEncoder().encode([move]), as: UTF8.self)),
                SQLBind(Player.two.rawValue), SQLBind(Date()), SQLBind(Date())
            )
            .run()

        try await app.testable().test(.GET, "v1/games/\(gameID)", headers: bearer(bob.token)) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let game = try res.content.decode(GameDetail.self)
            XCTAssertEqual(game.yourFleet, Fleets.bottomRight)
            XCTAssertEqual(game.moves, [move])
            XCTAssertTrue(game.summary.isYourTurn)
        }
    }

    /// Pretends a game was created `interval` earlier than it was.
    private func backdateCreation(of gameID: UUID, by interval: TimeInterval) async throws {
        let sql = try XCTUnwrap(app.db as? any SQLDatabase)
        try await sql.update(GameRecord.schema)
            .set("created_at", to: Date().addingTimeInterval(-interval))
            .where("id", .equal, gameID)
            .run()
    }
}

/// Blocks each hash on a semaphore, to fill the hashing queue on purpose.
private struct GatedHasher: PasswordHasher {
    let gate: DispatchSemaphore

    func hash<Password: DataProtocol>(_ password: Password) throws -> [UInt8] {
        gate.wait()
        return Array(password)
    }

    func verify<Password: DataProtocol, Digest: DataProtocol>(_ password: Password, created digest: Digest) throws -> Bool {
        gate.wait()
        return true
    }
}

/// A database whose queries never come back.
private struct UnresponsiveDatabase: SQLDatabase {
    let eventLoop: any EventLoop
    var logger: Logger { Logger(label: "unresponsive") }
    var dialect: any SQLDialect { SQLiteDialect() }

    func execute(sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> ()) -> EventLoopFuture<Void> {
        eventLoop.makeFutureWithTask {
            try await execute(sql: query, onRow)
        }
    }

    func execute(sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> ()) async throws {
        try await Task.sleep(for: .seconds(5))
    }
}

extension XCTestCase {
    /// Asserts that `operation` fails with the given API error code and a message starting with `message`.
    func assertAPIError<T>(
        _ code: APIErrorCode,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected error \(code.rawValue)", file: file, line: line)
        } catch let APIError.server(_, body) {
            XCTAssertEqual(body.code, code, file: file, line: line)
            XCTAssertTrue(body.message.hasPrefix(message), "\"\(body.message)\" doesn't start with \"\(message)\"", file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}
