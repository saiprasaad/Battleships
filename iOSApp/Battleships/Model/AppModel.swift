import BattleshipAPI
import BattleshipClient
import BattleshipCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

/// The app's root state: settings, the signed-in session, and both kinds of games.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let api: APIClient
    let session: SessionStore
    let online: OnlineGamesStore
    let solo: SoloGamesStore
    let feedback: any FeedbackPlayer

    /// A game to open, e.g. after tapping a notification.
    var pendingRoute: GameRoute?
    /// A new game to set up, e.g. a rematch chosen at the end of a battle.
    var newGameRequest: NewGameDraft?
    /// The game on screen right now. Its notifications don't need to be shown as banners.
    var visibleGameID: UUID?
    /// Set when the server rejected the saved session, so the app can explain the sign-out.
    var showsSessionExpired = false

    @ObservationIgnored private var devicePushToken: String?

    init(
        settings: AppSettings,
        tokenStorage: any TokenStorage,
        feedback: any FeedbackPlayer,
        soloDirectory: URL? = nil,
        urlSession: URLSession = .shared
    ) {
        self.settings = settings
        let api = APIClient(baseURL: settings.serverURL, session: urlSession)
        self.api = api
        self.session = SessionStore(api: api, tokenStorage: tokenStorage)
        self.online = OnlineGamesStore(api: api)
        self.solo = SoloGamesStore(directory: soloDirectory)
        self.feedback = feedback

        api.setUnauthorizedHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.sessionDidExpire() }
        }
    }

    var isSignedIn: Bool { session.isSignedIn }

    // MARK: Session

    func signIn(username: String, password: String) async throws {
        try await session.signIn(username: username, password: password)
        await sessionDidStart()
    }

    func register(username: String, password: String) async throws {
        try await session.register(username: username, password: password)
        await sessionDidStart()
    }

    func signOut() async {
        await unregisterDevice()
        await session.signOut()
        online.reset()
    }

    /// Deletes the account on the server. Battles in progress are resigned.
    func deleteAccount() async throws {
        try await session.deleteAccount()
        online.reset()
    }

    func sessionDidExpire() {
        guard session.isSignedIn else { return }
        session.clear()
        online.reset()
        showsSessionExpired = true
    }

    /// Points the app at another server. Accounts belong to a server, so this signs out first.
    func changeServer(to url: URL) async {
        guard url != settings.serverURL else { return }
        await signOut()
        settings.serverURL = url
        api.baseURL = url
    }

    private func sessionDidStart() async {
        online.connect()
        await online.refresh()
        await registerDeviceIfPossible()
    }

    // MARK: App lifecycle

    func appDidBecomeActive() {
        guard session.isSignedIn else { return }
        online.connect()
        Task {
            await online.refresh()
            await session.refreshAccount()
        }
    }

    func appDidEnterBackground() {
        online.disconnect()
    }

    // MARK: Push notifications

    var pushEnvironment: PushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }

    func didRegisterForPushNotifications(deviceToken: Data) async {
        devicePushToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        await registerDeviceIfPossible()
    }

    func open(_ route: GameRoute) {
        pendingRoute = route
    }

    /// Starts setting up a game with the same opponent and rules.
    func requestRematch(of route: GameRoute) {
        var draft = NewGameDraft()
        switch route {
        case let .solo(id):
            guard let match = solo.match(id) else { return }
            draft.opponent = .computer
            draft.difficulty = match.difficulty
            draft.mode = match.mode
        case let .online(id):
            guard let game = online.summary(for: id) else { return }
            draft.mode = game.mode
            if let opponent = game.opponent {
                draft.opponent = .friend
                draft.friendUsername = opponent.username
            } else {
                draft.opponent = .randomPlayer
            }
        }
        newGameRequest = draft
    }

    private func registerDeviceIfPossible() async {
        guard let devicePushToken, session.isSignedIn else { return }
        try? await api.registerDevice(DeviceRegistration(token: devicePushToken, environment: pushEnvironment))
    }

    private func unregisterDevice() async {
        guard let devicePushToken, session.isSignedIn else { return }
        try? await api.unregisterDevice(token: devicePushToken)
    }
}
