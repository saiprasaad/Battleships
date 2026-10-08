import BattleshipAPI
import BattleshipCore
import Foundation
import Testing

@Suite("Wire format")
struct WireFormatTests {
    static func json(_ value: some Encodable) throws -> String {
        let encoder = APICoding.makeEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func sampleDetail(status: GameStatus = .active) -> GameDetail {
        GameDetail(
            summary: GameSummary(
                id: UUID(uuidString: "6D3C1F7E-8E0B-4B8F-9C1A-2B3C4D5E6F70")!,
                mode: .classic,
                status: status,
                you: .two,
                opponent: PlayerSummary(id: UUID(), username: "alice", rating: 1016),
                turn: .two,
                outcome: nil,
                yourShipsRemaining: 5,
                opponentShipsRemaining: 4,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
            ),
            yourFleet: Rules.classic.randomFleet(),
            knownOpponentShips: [ShipPlacement(kind: .destroyer, origin: Coordinate("A1")!, orientation: .horizontal)],
            moves: [
                Move(player: .one, target: Coordinate("C3")!, result: .miss),
                Move(player: .two, target: Coordinate("A1")!, result: .hit),
                Move(player: .one, target: Coordinate("D4")!, result: .miss),
                Move(player: .two, target: Coordinate("A2")!, result: .sunk(.destroyer)),
                Move(player: .one, target: Coordinate("E5")!, result: .miss),
            ]
        )
    }

    @Test func movesAreCompact() throws {
        #expect(try Self.json(Move(player: .one, target: Coordinate("B7")!, result: .miss))
            == #"{"player":1,"result":"miss","target":"B7"}"#)
        #expect(try Self.json(Move(player: .two, target: Coordinate("J10")!, result: .sunk(.cruiser)))
            == #"{"player":2,"result":"sunk","ship":"cruiser","target":"J10"}"#)
    }

    @Test func datesAreISO8601() throws {
        let stats = PlayerStats(rating: 1000, wins: 0, losses: 0)
        let account = Account(id: UUID(), username: "bob", createdAt: Date(timeIntervalSince1970: 0), stats: stats)
        #expect(try Self.json(account).contains(#""createdAt":"1970-01-01T00:00:00Z""#))
    }

    @Test func eventsRoundTrip() throws {
        let events: [ServerEvent] = [
            .hello,
            .gameUpdated(Self.sampleDetail()),
            .gameRemoved(gameID: UUID(), reason: .declined),
        ]
        for event in events {
            let data = try APICoding.makeEncoder().encode(event)
            #expect(try APICoding.makeDecoder().decode(ServerEvent.self, from: data) == event)
        }
        #expect(try Self.json(ServerEvent.hello) == #"{"type":"hello"}"#)
    }

    @Test func externalSignInAnswersIsASessionOrATicket() throws {
        let stats = PlayerStats(rating: 1000, wins: 0, losses: 0)
        let account = Account(id: UUID(), username: "bob", createdAt: Date(timeIntervalSince1970: 0), stats: stats)
        let returning = ExternalSignInResponse(session: AuthResponse(token: "token", account: account))
        let data = try APICoding.makeEncoder().encode(returning)
        #expect(try APICoding.makeDecoder().decode(ExternalSignInResponse.self, from: data) == returning)

        let newcomer = ExternalSignInResponse(signupTicket: "ticket", suggestedUsername: "Captain4821")
        #expect(try Self.json(newcomer) == #"{"signupTicket":"ticket","suggestedUsername":"Captain4821"}"#)
    }

    @Test func providersWithoutGoogleStillDecode() throws {
        let providers = try APICoding.makeDecoder().decode(AuthProviders.self, from: Data(#"{"apple":true}"#.utf8))
        #expect(providers == AuthProviders(apple: true))
        #expect(try Self.json(AuthProviders(apple: false, googleClientID: "123-abc.apps.googleusercontent.com"))
            == #"{"apple":false,"googleClientID":"123-abc.apps.googleusercontent.com"}"#)
    }

    @Test func unknownErrorCodesStillDecode() throws {
        let body = try APICoding.makeDecoder().decode(
            APIErrorBody.self,
            from: Data(#"{"code":"brand_new_problem","message":"Something new."}"#.utf8)
        )
        #expect(body.code == APIErrorCode(rawValue: "brand_new_problem"))
        #expect(body.code != .notFound)
    }

    @Test func detailBuildsThePlayersPerspective() {
        let detail = Self.sampleDetail()
        let view = detail.perspective
        #expect(view.me == .two)
        #expect(view.isMyTurn)
        #expect(view.myShots.count == 2)
        #expect(view.targetMark(at: Coordinate("A1")!) == .sunk)
        #expect(view.enemyShipsRemaining == 4)
        #expect(view.homeMark(at: Coordinate("C3")!) == .miss)
    }

    @Test func turnIsIgnoredUntilTheGameStarts() {
        var detail = Self.sampleDetail(status: .invited)
        detail.moves = []
        #expect(detail.perspective.turn == nil)
        #expect(detail.summary.isIncomingChallenge)
        #expect(!detail.summary.isYourTurn)
    }

    @Test func summaryHelpers() {
        var summary = Self.sampleDetail().summary
        #expect(summary.isYourTurn)
        #expect(summary.didWin == nil)
        summary.status = .finished
        summary.outcome = Outcome(winner: .one, reason: .resignation)
        #expect(summary.didWin == false)
        summary.opponent = nil
        #expect(summary.opponentName == "Former player")
        summary.status = .matchmaking
        #expect(summary.opponentName == "Finding opponent…")
    }
}

@Suite("Credential policy")
struct CredentialPolicyTests {
    @Test(arguments: ["bob", "Captain_Nemo", "abcdefghij0123456789"])
    func acceptsGoodUsernames(username: String) {
        #expect(CredentialPolicy.usernameProblem(username) == nil)
    }

    @Test(arguments: ["", "ab", "abcdefghij0123456789x", "has space", "émile", "semi;colon", "dash-name"])
    func rejectsBadUsernames(username: String) {
        #expect(CredentialPolicy.usernameProblem(username) != nil)
    }

    @Test(arguments: ["Sh1thead", "FUCK_this", "admin", "Ad_min", "x_b1tch_x", "nigg3r", "Bullshit_Bob", "big_fuckup"])
    func refusesOffensiveAndReservedUsernames(username: String) {
        #expect(CredentialPolicy.usernameProblem(username) != nil)
    }

    @Test(arguments: [
        "Torpedo_Ted", "Admiral_Ackbar", "Grapeshot", "Scuttlebutt", "Mod_Squad_77", "Supporter",
        "Josh_17", "Ash_17", "Crush_It", "Push_It", "Matt_Watson", "Ashita", "Captain_Sai",
    ])
    func allowsInnocentUsernames(username: String) {
        #expect(CredentialPolicy.usernameProblem(username) == nil)
    }

    @Test func serversCanBlockMoreWords() {
        #expect(!CredentialPolicy.isOffensiveOrReserved("Kraken_Fan"))
        #expect(CredentialPolicy.isOffensiveOrReserved("Kraken_Fan", extraWords: ["KRAKEN"]))
    }

    @Test func passwordLength() {
        #expect(CredentialPolicy.passwordProblem("short") != nil)
        #expect(CredentialPolicy.passwordProblem("long enough") == nil)
        #expect(CredentialPolicy.passwordProblem(String(repeating: "x", count: 129)) != nil)
    }

    @Test func normalizesCase() {
        #expect(CredentialPolicy.normalized("Captain_Nemo") == "captain_nemo")
    }
}
