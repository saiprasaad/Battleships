#if canImport(UIKit)
import BattleshipAPI
import BattleshipCore
import SwiftUI
import Testing
import UIKit
@testable import Battleships

/// Renders the main screens with sample data and saves them as PNGs, for reviewing the UI without
/// clicking through it. Only runs when `SCREENSHOT_DIR` is set; CI sets it (via
/// `TEST_RUNNER_SCREENSHOT_DIR`) and uploads the images as a build artifact.
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
        try await capture(RootView().environment(app), "02-lobby-dark", to: output, style: .dark)
        try await capture(
            NavigationStack { BattleView(route: .solo(showcase.classicBattle), app: app) }.environment(app),
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
                Theme.battleBackdrop.ignoresSafeArea()
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
        try await capture(
            NavigationStack { BattleView(route: .online(showcase.onlineBattle), app: app) }.environment(app),
            "10-online-battle-ipad", to: output,
            size: CGSize(width: 1180, height: 820),
            regularWidth: true
        )
    }

    private func capture(
        _ view: some View,
        _ name: String,
        to directory: URL,
        style: UIUserInterfaceStyle = .light,
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

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try #require(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// A signed-in player with a lobby full of games in different states.
@MainActor
struct Showcase {
    let app: AppModel
    let classicBattle: UUID
    let quickBattle: UUID
    let challenge: UUID
    let onlineBattle: UUID

    init() throws {
        let defaults = UserDefaults(suiteName: "Showcase-\(UUID().uuidString)")!
        let account = Account(
            id: UUID(),
            username: "Captain_Sai",
            createdAt: Date(timeIntervalSinceNow: -86_400 * 120),
            stats: PlayerStats(rating: 1184, wins: 23, losses: 9)
        )
        defaults.set(try APICoding.makeEncoder().encode(account), forKey: "cachedAccount")
        app = AppModel(
            settings: AppSettings(defaults: defaults),
            tokenStorage: InMemoryTokenStorage(token: "showcase"),
            feedback: FeedbackRecorder(),
            soloDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
            defaults: defaults
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
#endif
