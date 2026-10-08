#if canImport(UIKit)
import BattleshipAPI
import BattleshipCore
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import Battleships

/// Renders the main screens with sample data and saves them as PNGs, for reviewing the UI without
/// clicking through it. Only runs when `SCREENSHOT_DIR` is set; CI sets it (via
/// `TEST_RUNNER_SCREENSHOT_DIR`) and uploads the images as a build artifact.
///
/// Full-screen images come out at the simulator's native resolution, opaque and in sRGB: exactly
/// what App Store Connect accepts. The App Store screenshots workflow
/// (`.github/workflows/app-store-screenshots.yml`) runs this same test on 6.9-inch and 6.3-inch
/// iPhone and 13-inch iPad simulators, then picks out the screens to upload (docs/app-store.md).
@MainActor
@Suite("Screenshots", .serialized)
struct ScreenshotTests {
    nonisolated static let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]

    @Test(.enabled(if: directory != nil))
    func renderScreens() async throws {
        let output = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let showcase = try Showcase()
        let app = showcase.app

        try await capture(RootView().environment(app), "01-lobby", to: output)
        try await capture(AuthSheet().environment(app), "02-sign-in", to: output)
        let aiming = BattleController(route: .solo(showcase.classicBattle), app: app)
        let perspective = try #require(aiming.perspective)
        let target = try #require(["F7", "G6", "E4", "H8"].compactMap { Coordinate($0) }.first { perspective.canTarget($0) })
        aiming.tapTarget(target)
        try await capture(
            NavigationStack { BattleView(controller: aiming) }.environment(app),
            "03-battle-vs-computer", to: output
        )
        try await capture(
            NavigationStack { FleetPlacementView(mode: .classic, confirmTitle: "Start Battle") { _ in } }.environment(app),
            "04-deploy-fleet", to: output
        )
        try await capture(NewGameSheet(draft: NewGameDraft()) { _ in }.environment(app), "05-new-battle", to: output)
        try await capture(
            NavigationStack { BattleView(route: .online(showcase.challenge), app: app) }.environment(app),
            "06-incoming-challenge", to: output
        )
        try await capture(
            ZStack {
                OceanBackdrop()
                GameOverOverlay(
                    didWin: true,
                    reason: .fleetDestroyed,
                    opponentName: "ahab",
                    stats: ShotStats(shotsFired: 41, hits: 17),
                    celebrates: true,
                    onRematch: {},
                    onClose: {}
                )
            },
            "07-victory", to: output
        )
        try await capture(ProfileView().environment(app), "08-profile", to: output)
        try await capture(
            NavigationStack { BattleView(route: .solo(showcase.quickBattle), app: app) }.environment(app),
            "09-quick-battle", to: output
        )
        // Both boards side by side, at the size of a landscape iPad, whatever the simulator. On an
        // iPad every screen here is already an iPad screen, so it's left out there.
        if UIDevice.current.userInterfaceIdiom != .pad {
            try await capture(
                NavigationStack { BattleView(route: .online(showcase.onlineBattle), app: app) }.environment(app),
                "10-online-battle-ipad", to: output,
                size: CGSize(width: 1180, height: 820),
                regularWidth: true
            )
        }
        try await capture(WelcomeView {}, "11-welcome", to: output)
        try await capture(
            ZStack {
                OceanBackdrop()
                GameOverOverlay(
                    didWin: false,
                    reason: .fleetDestroyed,
                    opponentName: "Computer (Admiral)",
                    stats: ShotStats(shotsFired: 52, hits: 14),
                    celebrates: false,
                    onRematch: {},
                    onClose: {}
                )
            },
            "12-defeat", to: output
        )
        try await capture(
            FleetSheet(controller: BattleController(route: .solo(showcase.classicBattle), app: app)).environment(app),
            "13-your-fleet", to: output
        )

        // The rankings come from the server, so this player's app talks to a stand-in for it.
        let ranked = try Showcase(urlSession: ShowcaseServer.session())
        try await capture(LeaderboardView().environment(ranked.app), "14-leaderboard", to: output)
    }

    /// Records the moments that move: a strip of frames over a few seconds, at about 12 frames a
    /// second, at 1x so a strip stays small. CI uploads them under `filmstrips/<moment>/`, where
    /// contact sheets of them show whether an animation reads well and lands on time.
    @Test(.enabled(if: directory != nil))
    func renderFilmstrips() async throws {
        let output = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true).appendingPathComponent("filmstrips", isDirectory: true)
        let showcase = try Showcase()
        let app = showcase.app

        // The player's shot hits, misses and sinks; the computer's reply lands on the home board.
        let classic = try #require(app.solo.match(showcase.classicBattle))
        let enemy = classic.battle.fleet(of: ComputerMatch.computer)
        let known = Set(classic.perspective.myShots.map(\.target))
        let battleship = try #require(enemy.first { $0.kind == .battleship })
        let hitTarget = try #require(battleship.cells.first { !known.contains($0) })
        let water = try #require(Rules.classic.allCoordinates.first { cell in !known.contains(cell) && !enemy.contains { $0.contains(cell) } })
        let cruiser = try #require(enemy.first { $0.kind == .cruiser })
        let lastCruiserCells = cruiser.cells.filter { !known.contains($0) }

        try await filmstrip("battle-hit", to: output, seconds: 2.6) {
            let controller = BattleController(route: .solo(showcase.classicBattle), app: app)
            controller.computerPause = 60_000...60_000
            return (AnyView(NavigationStack { BattleView(controller: controller) }.environment(app)), controller, { controller.tapTarget(hitTarget); Task { await controller.fire() } })
        }
        try await filmstrip("battle-miss", to: output, seconds: 2.2) {
            let controller = BattleController(route: .solo(showcase.classicBattle), app: app)
            controller.computerPause = 60_000...60_000
            return (AnyView(NavigationStack { BattleView(controller: controller) }.environment(app)), controller, { controller.tapTarget(water); Task { await controller.fire() } })
        }
        try await filmstrip("battle-sunk", to: output, seconds: 3.4) {
            var match = classic
            for cell in lastCruiserCells.dropLast() {
                try match.fire(at: cell)
                match.playComputerTurn()
            }
            app.solo.update(match)
            let controller = BattleController(route: .solo(showcase.classicBattle), app: app)
            controller.computerPause = 60_000...60_000
            let last = try #require(lastCruiserCells.last)
            return (AnyView(NavigationStack { BattleView(controller: controller) }.environment(app)), controller, { controller.tapTarget(last); Task { await controller.fire() } })
        }
        try await filmstrip("battle-incoming", to: output, seconds: 3.0) {
            app.solo.update(classic)
            let controller = BattleController(route: .solo(showcase.classicBattle), app: app)
            controller.computerPause = 400...400
            return (AnyView(NavigationStack { BattleView(controller: controller) }.environment(app)), controller, { controller.tapTarget(water); Task { await controller.fire() } })
        }

        // The end of a game, from the moment the result is shown.
        for (name, didWin, opponent) in [("victory", true, "ahab"), ("defeat", false, "Computer (Admiral)")] {
            try await filmstrip(name, to: output, seconds: 3.4) {
                let shows = ShowsOutcome()
                return (AnyView(OutcomeStrip(shows: shows, didWin: didWin, opponent: opponent)), nil, { shows.isOn = true })
            }
        }

        // Screens whose entrance is the show.
        try await filmstrip("welcome", to: output, seconds: 3.0, settle: 0) {
            (AnyView(WelcomeView {}), nil, {})
        }
        try await filmstrip("lobby", to: output, seconds: 2.6, settle: 0) {
            (AnyView(RootView().environment(app)), nil, {})
        }
        try await filmstrip("challenge", to: output, seconds: 2.6, settle: 0) {
            (AnyView(NavigationStack { BattleView(route: .online(showcase.challenge), app: app) }.environment(app)), nil, {})
        }
    }

    /// Shows `make()`'s view, waits `settle` seconds, runs its action, then saves frames for `seconds`.
    private func filmstrip(
        _ name: String,
        to directory: URL,
        seconds: Double,
        settle: Double = 1.5,
        make: @MainActor () throws -> (view: AnyView, controller: BattleController?, action: @MainActor () -> Void)
    ) async throws {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let (view, controller, action) = try make()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: scene.screen.bounds.size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        controller?.viewDidAppear()
        if settle > 0 {
            try await Task.sleep(for: .seconds(settle))
            if let controller {
                await controller.load()
            }
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let start = ContinuousClock.now
        action()
        var frame = 0
        while ContinuousClock.now - start < .seconds(seconds) {
            let image = renderer.image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let elapsed = (ContinuousClock.now - start) / .milliseconds(1)
            try #require(image.jpegData(compressionQuality: 0.82))
                .write(to: folder.appendingPathComponent(String(format: "%02d-%04dms.jpg", frame, Int(elapsed))))
            frame += 1
            try await Task.sleep(for: .milliseconds(80))
        }
        controller?.viewDidDisappear()
        window.isHidden = true
        window.rootViewController = nil
    }

    private func capture(
        _ view: some View,
        _ name: String,
        to directory: URL,
        style: UIUserInterfaceStyle = .dark,
        size: CGSize? = nil,
        regularWidth: Bool = false
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size ?? scene.screen.bounds.size)
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: AnyView(view))
        if regularWidth {
            host.traitOverrides.horizontalSizeClass = .regular
        }
        window.rootViewController = host
        window.makeKeyAndVisible()

        // Let layout, data loading and entrance animations settle.
        try await Task.sleep(for: .seconds(2.5))

        // At the screen's own scale, so a full-screen capture has the device's native resolution,
        // and opaque 8-bit sRGB, because App Store Connect rejects screenshots with an alpha channel.
        let format = UIGraphicsImageRendererFormat()
        format.scale = scene.screen.scale
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try #require(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// A switch a filmstrip flips after its first frame, e.g. to bring in the game-over card.
@MainActor
@Observable
private final class ShowsOutcome {
    var isOn = false
}

/// The end of a battle arriving over the ocean, for the victory and defeat filmstrips.
private struct OutcomeStrip: View {
    let shows: ShowsOutcome
    let didWin: Bool
    let opponent: String

    var body: some View {
        ZStack {
            OceanBackdrop()
            if shows.isOn {
                GameOverOverlay(
                    didWin: didWin,
                    reason: .fleetDestroyed,
                    opponentName: opponent,
                    stats: ShotStats(shotsFired: 41, hits: 17),
                    celebrates: didWin,
                    onRematch: {},
                    onClose: {}
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: shows.isOn)
    }
}

/// A signed-in player with a lobby full of games in different states.
@MainActor
struct Showcase {
    /// The player's account, fixed so that the sample leaderboard can mark their row as theirs.
    nonisolated static let playerID = UUID(uuidString: "C0FFEE00-5EA5-4B47-8B00-000000000001")!
    nonisolated static let playerName = "Captain_Sai"

    let app: AppModel
    let classicBattle: UUID
    let quickBattle: UUID
    let challenge: UUID
    let onlineBattle: UUID

    /// - Parameter urlSession: what the app talks to the server with. With the default there's no
    ///   server, so screens show what they've cached.
    init(urlSession: URLSession = .shared) throws {
        let defaults = UserDefaults(suiteName: "Showcase-\(UUID().uuidString)")!
        let account = Account(
            id: Self.playerID,
            username: Self.playerName,
            createdAt: Date(timeIntervalSinceNow: -86_400 * 120),
            stats: PlayerStats(rating: 1184, wins: 23, losses: 9)
        )
        defaults.set(try APICoding.makeEncoder().encode(account), forKey: "cachedAccount")
        defaults.set(true, forKey: "hasSeenWelcome")
        app = AppModel(
            settings: AppSettings(defaults: defaults),
            tokenStorage: InMemoryTokenStorage(token: "showcase"),
            feedback: FeedbackRecorder(),
            soloDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
            defaults: defaults,
            urlSession: urlSession
        )

        var generator = SeededRandomNumberGenerator(seed: 2026)

        // A classic game against the computer, a dozen shots in: one ship sunk, one hit.
        var classic = try app.solo.start(mode: .classic, difficulty: .hard, fleet: Rules.classic.randomFleet(using: &generator))
        let enemy = classic.battle.fleet(of: ComputerMatch.computer)
        let occupied = Set(enemy.flatMap(\.cells))
        let destroyer = try #require(enemy.first { $0.kind == .destroyer })
        let cruiser = try #require(enemy.first { $0.kind == .cruiser })
        let water = Rules.classic.allCoordinates.filter { !occupied.contains($0) }.shuffled(using: &generator)
        for target in Array(water.prefix(4)) + destroyer.cells + Array(water.dropFirst(4).prefix(5)) + [cruiser.origin] {
            try classic.fire(at: target)
            classic.playComputerTurn(using: &generator)
        }
        app.solo.update(classic)
        classicBattle = classic.id

        // The original 5×5 rules.
        var quick = try app.solo.start(mode: .quick, difficulty: .medium, fleet: Rules.quick.randomFleet(using: &generator))
        for target in Rules.quick.allCoordinates.shuffled(using: &generator).prefix(5) {
            try quick.fire(at: target)
            quick.playComputerTurn(using: &generator)
        }
        app.solo.update(quick)
        quickBattle = quick.id

        // Online games in every state.
        let invite = Self.game(mode: .classic, status: .invited, you: .two, opponent: "nemo", rating: 1240, minutesAgo: 3)
        app.online.apply(invite)
        challenge = invite.id

        var duel = try Battle(mode: .classic, fleetOne: Rules.classic.randomFleet(using: &generator), fleetTwo: Rules.classic.randomFleet(using: &generator))
        let duelTargets = duel.fleet(of: .two).flatMap(\.cells).prefix(6)
        for (index, target) in duelTargets.enumerated() {
            try duel.fire(.one, at: target)
            try duel.fire(.two, at: Coordinate(row: index, column: (index * 3) % 10))
        }
        let ahab = Self.game(battle: duel, you: .one, opponent: "ahab", rating: 1210, minutesAgo: 12)
        app.online.apply(ahab)
        onlineBattle = ahab.id

        var quickDuel = try Battle(mode: .quick, fleetOne: Rules.quick.randomFleet(using: &generator), fleetTwo: Rules.quick.randomFleet(using: &generator))
        try quickDuel.fire(.one, at: Coordinate("C3")!)
        app.online.apply(Self.game(battle: quickDuel, you: .one, opponent: "drake", rating: 1088, minutesAgo: 47))

        app.online.apply(Self.game(mode: .classic, status: .matchmaking, you: .one, opponent: nil, rating: 0, minutesAgo: 90))

        var won = try Battle(mode: .classic, fleetOne: Rules.classic.randomFleet(using: &generator), fleetTwo: Rules.classic.randomFleet(using: &generator))
        try won.resign(.two)
        app.online.apply(Self.game(battle: won, you: .one, opponent: "hornblower", rating: 1302, minutesAgo: 60 * 26))
    }

    private static func game(
        mode: GameMode,
        status: GameStatus,
        you: Player,
        opponent: String?,
        rating: Int,
        minutesAgo: Double
    ) -> GameDetail {
        let date = Date(timeIntervalSinceNow: -minutesAgo * 60)
        let summary = GameSummary(
            id: UUID(),
            mode: mode,
            status: status,
            you: you,
            opponent: opponent.map { PlayerSummary(id: UUID(), username: $0, rating: rating) },
            turn: nil,
            outcome: nil,
            yourShipsRemaining: mode.rules.fleet.count,
            opponentShipsRemaining: mode.rules.fleet.count,
            createdAt: date,
            updatedAt: date
        )
        let fleet = status == .invited && you == .two ? [] : mode.rules.randomFleet()
        return GameDetail(summary: summary, yourFleet: fleet, knownOpponentShips: [], moves: [])
    }

    private static func game(battle: Battle, you: Player, opponent: String, rating: Int, minutesAgo: Double) -> GameDetail {
        let date = Date(timeIntervalSinceNow: -minutesAgo * 60)
        let summary = GameSummary(
            id: UUID(),
            mode: battle.mode,
            status: battle.isOver ? .finished : .active,
            you: you,
            opponent: PlayerSummary(id: UUID(), username: opponent, rating: rating),
            turn: battle.turn,
            outcome: battle.outcome,
            yourShipsRemaining: battle.remainingShips(of: you),
            opponentShipsRemaining: battle.remainingShips(of: you.opponent),
            createdAt: date,
            updatedAt: date
        )
        return GameDetail(
            summary: summary,
            yourFleet: battle.fleet(of: you),
            knownOpponentShips: battle.isOver ? battle.fleet(of: you.opponent) : battle.sunkShips(of: you.opponent),
            moves: battle.moves
        )
    }
}

/// Stands in for the game server, so screens that load from it can be shown without one. It
/// answers with sample rankings, an empty list of blocked players, and otherwise as if the server
/// were down.
final class ShowcaseServer: URLProtocol {
    /// A session whose requests are all answered here, so none leave the device.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShowcaseServer.self]
        return URLSession(configuration: configuration)
    }

    /// The top ten, with the showcased player in fifth place. Opponents from the showcase lobby
    /// have the same ratings here.
    private static let leaderboard: Data = {
        let captains: [(name: String, rating: Int, wins: Int, losses: Int)] = [
            ("aubrey", 1355, 41, 17),
            ("hornblower", 1302, 36, 18),
            ("nemo", 1240, 30, 19),
            ("ahab", 1210, 27, 20),
            (Showcase.playerName, 1184, 23, 9),
            ("queequeg", 1150, 19, 16),
            ("drake", 1088, 15, 15),
            ("marlow", 1061, 12, 13),
            ("bowline", 1032, 9, 10),
            ("seawolf", 1004, 6, 8),
        ]
        let entries = captains.enumerated().map { index, captain in
            LeaderboardEntry(
                rank: index + 1,
                player: PlayerSummary(
                    id: captain.name == Showcase.playerName ? Showcase.playerID : UUID(),
                    username: captain.name,
                    rating: captain.rating
                ),
                wins: captain.wins,
                losses: captain.losses
            )
        }
        return (try? APICoding.makeEncoder().encode(entries)) ?? Data("[]".utf8)
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: Data? = if path.hasSuffix("/v1/leaderboard") {
            Self.leaderboard
        } else if path.hasSuffix("/v1/me/blocked") {
            Data("[]".utf8)
        } else {
            nil
        }
        guard let url = request.url, let body,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
