import BattleshipAPI
import BattleshipClient
import BattleshipCore
@testable import BattleshipServer
import XCTVapor
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Blocking, reporting, the admin tools, the public pages and the username filter.
final class ModerationTests: ServerTestCase {
    func testBlocksStopChallengesBothWays() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)
        try await alice.block(playerID: bob.account().id)

        // Alice is told why; Bob can't tell Alice exists.
        await assertAPIError(.playerBlocked) {
            try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
        }
        await assertAPIError(.playerNotFound) {
            try await bob.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "alice"))
        }

        try await alice.unblock(playerID: bob.account().id)
        _ = try await bob.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "alice"))
    }

    func testBlockingWithdrawsPendingChallengesBothWays() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)
        let carol = try await signedInClient("carol", baseURL: baseURL)
        let bobEvents = try await openEventSocket(for: bob)
        try await bobEvents.next { $0 == .hello }

        let toBob = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "bob"))
        let fromCarol = try await carol.createGame(CreateGameRequest(mode: .quick, fleet: Rules.quick.randomFleet(), opponent: "alice"))
        try await bob.block(playerID: alice.account().id)

        try await bobEvents.next { $0 == .gameRemoved(gameID: toBob.id, reason: .cancelled) }
        let bobsGames = try await bob.games()
        XCTAssertEqual(bobsGames, [])
        // Only challenges between the two of them go.
        let alicesGames = try await alice.games()
        XCTAssertEqual(alicesGames.map(\.id), [fromCarol.id])

        // The other direction: Bob challenged Carol, then Carol blocks him.
        let toCarol = try await bob.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft, opponent: "carol"))
        try await carol.block(playerID: bob.account().id)
        await assertAPIError(.gameNotFound) { try await bob.game(id: toCarol.id) }
    }

    func testMatchmakingNeverPairsBlockedPlayers() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)
        let carol = try await signedInClient("carol", baseURL: baseURL)
        try await alice.block(playerID: bob.account().id)

        let alicesWait = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft))
        // Bob is blocked by Alice, so he queues instead of joining her...
        let bobsWait = try await bob.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.bottomRight))
        XCTAssertEqual(bobsWait.summary.status, .matchmaking)
        XCTAssertNotEqual(bobsWait.id, alicesWait.id)
        // ...and Carol gets the longest-waiting game she can have: Alice's.
        let carolsGame = try await carol.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.bottomRight))
        XCTAssertEqual(carolsGame.id, alicesWait.id)
        XCTAssertEqual(carolsGame.summary.status, .active)

        // The other way round: Alice (who blocked Bob) doesn't get his waiting game either.
        let alicesNext = try await alice.createGame(CreateGameRequest(mode: .classic, fleet: Fleets.topLeft))
        XCTAssertEqual(alicesNext.summary.status, .matchmaking)
        XCTAssertNotEqual(alicesNext.id, bobsWait.id)
    }

    func testSearchHidesBlockedPlayersBothWays() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)
        let carol = try await signedInClient("carol", baseURL: baseURL)
        try await alice.block(playerID: bob.account().id)

        let alicesSearch = try await alice.searchPlayers(prefix: "bo")
        XCTAssertEqual(alicesSearch, [])
        let bobsSearch = try await bob.searchPlayers(prefix: "ali")
        XCTAssertEqual(bobsSearch, [])
        let carolsSearch = try await carol.searchPlayers(prefix: "b")
        XCTAssertEqual(carolsSearch.map(\.username), ["bob"])
    }

    func testBlockedPlayersList() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)
        let bobID = try await bob.account().id

        try await alice.block(playerID: bobID)
        try await alice.block(playerID: bobID)
        let blocked = try await alice.blockedPlayers()
        XCTAssertEqual(blocked.map(\.username), ["bob"], "blocking twice is harmless")
        let bobsList = try await bob.blockedPlayers()
        XCTAssertEqual(bobsList, [])

        try await alice.unblock(playerID: bobID)
        let afterUnblocking = try await alice.blockedPlayers()
        XCTAssertEqual(afterUnblocking, [])
        await assertAPIError(.badRequest) { try await alice.block(playerID: alice.account().id) }
        await assertAPIError(.playerNotFound) { try await alice.block(playerID: UUID()) }
    }

    func testReportingAgainUpdatesTheReport() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)
        let bobID = try await bob.account().id
        let gameID = UUID()

        try await alice.report(playerID: bobID, reason: .harassment)
        try await alice.report(playerID: bobID, reason: .cheating, gameID: gameID)
        let reports = try await Report.query(on: app.db).all()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.reason, ReportReason.cheating.rawValue)
        XCTAssertEqual(reports.first?.gameID, gameID)
        XCTAssertEqual(reports.first?.$reported.id, bobID)

        // Another player's report is its own.
        try await bob.report(playerID: alice.account().id, reason: .offensiveUsername)
        let total = try await Report.query(on: app.db).count()
        XCTAssertEqual(total, 2)
        await assertAPIError(.badRequest) { try await alice.report(playerID: alice.account().id, reason: .other) }
        await assertAPIError(.playerNotFound) { try await alice.report(playerID: UUID(), reason: .other) }
    }

    func testDeletingAnAccountRemovesItsBlocksAndReports() async throws {
        let baseURL = try await startServer()
        let alice = try await signedInClient("alice", baseURL: baseURL)
        let bob = try await signedInClient("bob", baseURL: baseURL)
        let carol = try await signedInClient("carol", baseURL: baseURL)
        let aliceID = try await alice.account().id
        try await alice.block(playerID: bob.account().id)
        try await carol.block(playerID: aliceID)
        try await alice.report(playerID: bob.account().id, reason: .harassment)
        try await carol.report(playerID: aliceID, reason: .offensiveUsername)
        try await bob.report(playerID: carol.account().id, reason: .cheating)

        try await alice.deleteAccount()

        let blocks = try await Block.query(on: app.db).count()
        XCTAssertEqual(blocks, 0)
        let reports = try await Report.query(on: app.db).all()
        let carolID = try await carol.account().id
        XCTAssertEqual(reports.map(\.$reported.id), [carolID], "only reports not involving Alice remain")
    }

    // MARK: Admin

    func testAdminEndpointsDontExistWithoutAToken() async throws {
        let anyToken = bearer(String(repeating: "x", count: 32))
        for (method, path) in [(HTTPMethod.GET, "v1/admin/reports"), (.DELETE, "v1/admin/reports/\(UUID())"), (.DELETE, "v1/admin/players/\(UUID())")] {
            try await app.testable().test(method, path, headers: anyToken) { res async throws in
                XCTAssertEqual(res.status, .notFound, path)
                XCTAssertEqual(try res.content.decode(APIErrorBody.self).code, .notFound, path)
            }
        }
    }

    func testAdminEndpoints() async throws {
        let adminToken = "an-admin-token-for-tests-0123456789"
        try await restartApp(environment: ["ADMIN_TOKEN": adminToken])
        let alice = try await register("alice")
        let bob = try await register("bob")
        try await app.testable().test(.POST, "v1/players/\(bob.id)/report", headers: bearer(alice.token), beforeRequest: { req in
            try req.content.encode(ReportPlayerRequest(reason: .offensiveUsername))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .noContent)
        })

        // No token, a wrong token, or a player's session token: refused.
        for headers in [HTTPHeaders(), bearer("not-the-admin-token-at-all-000"), bearer(alice.token)] {
            try await app.testable().test(.GET, "v1/admin/reports", headers: headers) { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
                XCTAssertEqual(try res.content.decode(APIErrorBody.self).code, .unauthorized)
            }
        }

        var reportID: UUID?
        try await app.testable().test(.GET, "v1/admin/reports", headers: bearer(adminToken)) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let reports = try res.content.decode([AdminController.ReportEntry].self)
            XCTAssertEqual(reports.map(\.reported.username), ["bob"])
            XCTAssertEqual(reports.first?.reportedBy, "alice")
            XCTAssertEqual(reports.first?.reason, .offensiveUsername)
            reportID = reports.first?.id
        }
        let id = try XCTUnwrap(reportID)
        try await app.testable().test(.DELETE, "v1/admin/reports/\(id)", headers: bearer(adminToken)) { res async in
            XCTAssertEqual(res.status, .noContent)
        }
        try await app.testable().test(.GET, "v1/admin/reports", headers: bearer(adminToken)) { res async throws in
            XCTAssertEqual(try res.content.decode([AdminController.ReportEntry].self).count, 0)
        }

        try await app.testable().test(.DELETE, "v1/admin/players/\(bob.id)", headers: bearer(adminToken)) { res async in
            XCTAssertEqual(res.status, .noContent)
        }
        let bobRecord = try await User.find(bob.id, on: app.db)
        XCTAssertNil(bobRecord)
        try await app.testable().test(.GET, "v1/me", headers: bearer(bob.token)) { res async in
            XCTAssertEqual(res.status, .unauthorized)
        }
        try await app.testable().test(.DELETE, "v1/admin/players/\(bob.id)", headers: bearer(adminToken)) { res async in
            XCTAssertEqual(res.status, .notFound)
        }
    }

    // MARK: Public pages

    func testPublicPages() async throws {
        for path in ["/", "/privacy", "/support", "/terms"] {
            try await app.testable().test(.GET, path) { res async in
                XCTAssertEqual(res.status, .ok, path)
                XCTAssertEqual(res.headers.contentType, .html, path)
                XCTAssertTrue(res.body.string.contains("<html"), path)
                XCTAssertTrue(res.body.string.contains("contact the people who run this server") || path == "/", path)
            }
        }
    }

    func testTermsOfUse() async throws {
        try await app.testable().test(.GET, "/terms") { res async in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("zero tolerance"))
            XCTAssertTrue(html.contains("Report"))
            XCTAssertTrue(html.contains(#"<a href="/privacy">"#))
        }
        // Linked from every other page.
        for path in ["/", "/privacy", "/support"] {
            try await app.testable().test(.GET, path) { res async in
                XCTAssertTrue(res.body.string.contains(#"<a href="/terms">"#), path)
            }
        }
    }

    func testPublicPagesShowTheSupportAddressEscaped() async throws {
        try await restartApp(environment: ["SUPPORT_EMAIL": "o'brien&co@example.com"])
        for path in ["/privacy", "/support", "/terms"] {
            try await app.testable().test(.GET, path) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(#"<a href="mailto:o&#39;brien&amp;co@example.com">o&#39;brien&amp;co@example.com</a>"#), path)
                XCTAssertFalse(html.contains("o'brien&co"), path)
            }
        }
    }

    // MARK: Usernames

    func testOffensiveAndReservedUsernamesAreRefused() async throws {
        try await restartApp(environment: ["BLOCKED_USERNAME_WORDS": " kraken, squid "])
        for username in ["admin", "Support_", "Sh1tlord", "big_bastard", "BigKraken99", "squidward"] {
            try await app.testable().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(Credentials(username: username, password: "correct horse battery"))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest, username)
                XCTAssertEqual(try res.content.decode(APIErrorBody.self).code, .invalidUsername, username)
            })
        }
        try await register("Kraft_Dinner")
    }

    func testServerWordsOnlyApplyWhenConfigured() async throws {
        try await register("BigKraken99")
    }
}
