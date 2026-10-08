import BattleshipAPI
import BattleshipCore
@testable import BattleshipServer
import XCTVapor

/// Request-level behaviour: error format, authorization, rate limiting, information hiding.
final class HTTPBehaviorTests: ServerTestCase {
    private func register(_ username: String) async throws -> (token: String, id: UUID) {
        var result: AuthResponse?
        try await app.testable().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(Credentials(username: username, password: "correct horse battery"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .created)
            result = try res.content.decode(AuthResponse.self)
        })
        let auth = try XCTUnwrap(result)
        return (auth.token, auth.account.id)
    }

    private func bearer(_ token: String) -> HTTPHeaders {
        ["Authorization": "Bearer \(token)"]
    }

    func testHealthCheck() async throws {
        try await app.testable().test(.GET, "health") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, #"{"status":"ok"}"#)
        }
    }

    func testErrorsUseTheSharedShape() async throws {
        try await app.testable().test(.GET, "v1/games") { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
            XCTAssertEqual(try res.content.decode(APIErrorBody.self).code, .unauthorized)
        }
        try await app.testable().test(.GET, "v1/games", headers: bearer("not-a-real-token")) { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        }
        try await app.testable().test(.GET, "v1/nowhere") { res async throws in
            XCTAssertEqual(res.status, .notFound)
            XCTAssertEqual(try res.content.decode(APIErrorBody.self).code, .notFound)
        }
        try await app.testable().test(.POST, "v1/auth/login", beforeRequest: { req in
            req.headers.contentType = .json
            req.body = ByteBuffer(string: "{not json")
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .badRequest)
            XCTAssertEqual(try res.content.decode(APIErrorBody.self).code, .badRequest)
        })
    }

    func testStrangersCannotSeeOrTouchAGame() async throws {
        let alice = try await register("alice")
        let bob = try await register("bob")
        let eve = try await register("eve")

        var gameID: UUID?
        try await app.testable().test(.POST, "v1/games", headers: bearer(alice.token), beforeRequest: { req in
            try req.content.encode(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .created)
            gameID = try res.content.decode(GameDetail.self).id
        })
        let id = try XCTUnwrap(gameID)

        try await app.testable().test(.GET, "v1/games/\(id)", headers: bearer(eve.token)) { res async throws in
            XCTAssertEqual(res.status, .notFound)
            XCTAssertEqual(try res.content.decode(APIErrorBody.self).code, .gameNotFound)
        }
        try await app.testable().test(.POST, "v1/games/\(id)/accept", headers: bearer(eve.token), beforeRequest: { req in
            try req.content.encode(AcceptChallengeRequest(fleet: Fleets.bottomRight))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
        // The challenger can't accept their own challenge, and the challenged player can't cancel it.
        try await app.testable().test(.POST, "v1/games/\(id)/accept", headers: bearer(alice.token), beforeRequest: { req in
            try req.content.encode(AcceptChallengeRequest(fleet: Fleets.bottomRight))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .conflict)
        })
        try await app.testable().test(.POST, "v1/games/\(id)/cancel", headers: bearer(bob.token)) { res async in
            XCTAssertEqual(res.status, .conflict)
        }
        try await app.testable().test(.GET, "v1/games/not-a-uuid", headers: bearer(bob.token)) { res async in
            XCTAssertEqual(res.status, .notFound)
        }
    }

    func testOpponentFleetNeverLeaksOverTheWire() async throws {
        let alice = try await register("alice")
        let bob = try await register("bob")

        var gameID: UUID?
        try await app.testable().test(.POST, "v1/games", headers: bearer(alice.token), beforeRequest: { req in
            try req.content.encode(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
        }, afterResponse: { res async throws in
            gameID = try res.content.decode(GameDetail.self).id
        })
        let id = try XCTUnwrap(gameID)
        try await app.testable().test(.POST, "v1/games/\(id)/accept", headers: bearer(bob.token), beforeRequest: { req in
            try req.content.encode(AcceptChallengeRequest(fleet: Fleets.bottomRight))
        }, afterResponse: { _ async in })

        // Alice hits (but doesn't sink) Bob's carrier.
        try await app.testable().test(.POST, "v1/games/\(id)/shots", headers: bearer(alice.token), beforeRequest: { req in
            try req.content.encode(FireRequest(target: Coordinate("J6")!))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let body = res.body.string
            // None of Bob's ship origins appear in Alice's view.
            for ship in Fleets.bottomRight {
                XCTAssertFalse(body.contains(#""origin":"\#(ship.origin.notation)""#), "leaked \(ship.kind)")
            }
        })
    }

    func testFiringValidation() async throws {
        let alice = try await register("alice")
        let bob = try await register("bob")
        var gameID: UUID?
        try await app.testable().test(.POST, "v1/games", headers: bearer(alice.token), beforeRequest: { req in
            try req.content.encode(CreateGameRequest(mode: .quick, fleet: Rules.quick.randomFleet(), opponent: "bob"))
        }, afterResponse: { res async throws in
            gameID = try res.content.decode(GameDetail.self).id
        })
        let id = try XCTUnwrap(gameID)
        try await app.testable().test(.POST, "v1/games/\(id)/accept", headers: bearer(bob.token), beforeRequest: { req in
            try req.content.encode(AcceptChallengeRequest(fleet: Rules.quick.randomFleet()))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })

        // Quick games are 5×5, so F1 is off the board.
        try await app.testable().test(.POST, "v1/games/\(id)/shots", headers: bearer(alice.token), beforeRequest: { req in
            try req.content.encode(FireRequest(target: Coordinate("F1")!))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .badRequest)
            XCTAssertEqual(try res.content.decode(APIErrorBody.self).code, .outOfBounds)
        })
        try await app.testable().test(.POST, "v1/games/\(id)/shots", headers: bearer(alice.token), beforeRequest: { req in
            req.headers.contentType = .json
            req.body = ByteBuffer(string: #"{"target":"Z99"}"#)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testAuthEndpointsAreRateLimited() async throws {
        let limiter = RateLimiter(requestsPerMinute: 3)
        let start = Date()
        for _ in 0..<3 {
            let allowed = await limiter.consume("1.2.3.4", now: start)
            XCTAssertTrue(allowed)
        }
        let blocked = await limiter.consume("1.2.3.4", now: start)
        XCTAssertFalse(blocked)
        let otherClient = await limiter.consume("5.6.7.8", now: start)
        XCTAssertTrue(otherClient, "limits are per client")
        let later = await limiter.consume("1.2.3.4", now: start.addingTimeInterval(20))
        XCTAssertTrue(later, "allowance refills over time")

        // And it is wired up in front of sign-in.
        try await app.asyncShutdown()
        setenv("AUTH_RATE_LIMIT_PER_MINUTE", "2", 1)
        defer { unsetenv("AUTH_RATE_LIMIT_PER_MINUTE") }
        app = try await Application.make(.testing)
        try await configure(app, pushService: push)

        var statuses: [HTTPStatus] = []
        for _ in 0..<3 {
            try await app.testable().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(Credentials(username: "nobody", password: "whatever123"))
            }, afterResponse: { res async in
                statuses.append(res.status)
            })
        }
        XCTAssertEqual(statuses, [.unauthorized, .unauthorized, .tooManyRequests])
    }

    func testDeviceRegistration() async throws {
        let alice = try await register("alice")
        let bob = try await register("bob")
        let token = String(repeating: "ab", count: 32)

        try await app.testable().test(.POST, "v1/devices", headers: bearer(alice.token), beforeRequest: { req in
            try req.content.encode(DeviceRegistration(token: "not hex!", environment: .sandbox))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
        for user in [alice, bob] {
            try await app.testable().test(.POST, "v1/devices", headers: bearer(user.token), beforeRequest: { req in
                try req.content.encode(DeviceRegistration(token: token.uppercased(), environment: .sandbox))
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .noContent)
            })
        }

        // The phone changed hands: it now belongs to Bob only.
        let devices = try await Device.query(on: app.db).all()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.$user.id, bob.id)
        XCTAssertEqual(devices.first?.token, token)

        try await app.testable().test(.DELETE, "v1/devices/\(token)", headers: bearer(bob.token)) { res async in
            XCTAssertEqual(res.status, .noContent)
        }
        let remaining = try await Device.query(on: app.db).count()
        XCTAssertEqual(remaining, 0)
    }

    func testLeaderboardSharesRanksOnTies() async throws {
        for (name, rating, wins) in [("ann", 1100, 3), ("ben", 1050, 2), ("cat", 1050, 1), ("dan", 990, 0), ("eli", 1000, 0)] {
            let user = User(username: name, passwordHash: "x")
            user.rating = rating
            user.wins = wins
            user.losses = name == "dan" ? 1 : 0
            try await user.save(on: app.db)
        }
        let viewer = try await register("viewer")
        try await app.testable().test(.GET, "v1/leaderboard", headers: bearer(viewer.token)) { res async throws in
            let entries = try res.content.decode([LeaderboardEntry].self)
            // Players who haven't finished a game (eli, viewer) aren't ranked.
            XCTAssertEqual(entries.map(\.player.username), ["ann", "ben", "cat", "dan"])
            XCTAssertEqual(entries.map(\.rank), [1, 2, 2, 4])
        }
    }
}

final class RatingAndCopyTests: XCTestCase {
    func testEloIsZeroSumAndRewardsUpsets() {
        XCTAssertEqual(Elo.ratings(winner: 1000, loser: 1000).winner, 1016)
        XCTAssertEqual(Elo.ratings(winner: 1000, loser: 1000).loser, 984)

        let upset = Elo.ratings(winner: 1000, loser: 1400)
        let expected = Elo.ratings(winner: 1400, loser: 1000)
        XCTAssertGreaterThan(upset.winner - 1000, expected.winner - 1400)
        XCTAssertEqual(upset.winner - 1000, 1400 - upset.loser)
        XCTAssertGreaterThanOrEqual(Elo.ratings(winner: 3000, loser: 100).winner, 3001, "a win is always worth something")
    }

    func testPushCopy() {
        let id = UUID()
        XCTAssertEqual(
            PushMessage.incoming(Move(player: .one, target: Coordinate("B7")!, result: .miss), from: "ann", gameID: id).body,
            "ann fired at B7 and missed."
        )
        XCTAssertEqual(
            PushMessage.incoming(Move(player: .one, target: Coordinate("B7")!, result: .hit), from: "ann", gameID: id).body,
            "ann hit your ship at B7!"
        )
        XCTAssertEqual(
            PushMessage.incoming(Move(player: .one, target: Coordinate("B7")!, result: .sunk(.submarine)), from: "ann", gameID: id).body,
            "ann sank your Submarine!"
        )
    }
}
