#if canImport(UIKit)
import BattleshipAPI
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Battleships

/// The profile and leaderboard moments: the podium rising with the ranked cascade, the rating pill
/// rolling to a new rating after an online game, and the Effects preview playing a hit.
extension ScreenshotTests {
    @Test(.enabled(if: ScreenshotTests.directory != nil))
    func renderLeaderboardFilmstrips() async throws {
        let output = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true).appendingPathComponent("filmstrips", isDirectory: true)
        // The rankings come from the server, so this player's app talks to a stand-in for it: the
        // strip starts on the loader and runs through the podium's reveal and the rows' cascade.
        let ranked = try Showcase(urlSession: ShowcaseServer.session())
        try await filmstrip("leaderboard", to: output, seconds: 3.0, settle: 0) {
            (AnyView(LeaderboardView().environment(ranked.app)), nil, {})
        }
    }

    @Test(.enabled(if: ScreenshotTests.directory != nil))
    func renderProfileFilmstrips() async throws {
        let output = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true).appendingPathComponent("filmstrips", isDirectory: true)

        // A refresh brings a higher rating, so the pill rolls up with the delta chip floating.
        let promoted = try Showcase(urlSession: RatingRefreshServer.session())
        try await filmstrip("profile-rating", to: output, seconds: 3.4) {
            let app = promoted.app
            return (AnyView(ProfileView().environment(app)), nil, { @MainActor in Task { await app.session.refreshAccount() } })
        }

        // Changing the Effects level plays one hit on the preview's water.
        let showcase = try Showcase()
        try await filmstrip("effects-preview", to: output, seconds: 2.2) {
            let app = showcase.app
            return (AnyView(NavigationStack { EffectsSettingsView() }.environment(app)), nil, { @MainActor in app.settings.effectsLevel = .reduced })
        }
    }
}

/// Stands in for the server for the profile strip: the player's account comes back twelve points
/// up, as it does after an online win; everything else answers as if the server were down.
final class RatingRefreshServer: URLProtocol {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RatingRefreshServer.self]
        return URLSession(configuration: configuration)
    }

    private static let account: Data = {
        let account = Account(
            id: Showcase.playerID,
            username: Showcase.playerName,
            createdAt: Date(timeIntervalSinceNow: -86_400 * 120),
            stats: PlayerStats(rating: 1196, wins: 24, losses: 9)
        )
        return (try? APICoding.makeEncoder().encode(account)) ?? Data("{}".utf8)
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: Data? = if path.hasSuffix("/v1/me") {
            Self.account
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
