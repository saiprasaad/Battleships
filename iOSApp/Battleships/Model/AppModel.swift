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
    private static let devicePushTokenKey = "devicePushToken"

    let settings: AppSettings
    let api: APIClient
    let session: SessionStore
    let online: OnlineGamesStore
    let moderation: ModerationStore
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

    @ObservationIgnored private let defaults: UserDefaults

    init(
        settings: AppSettings,
        tokenStorage: any TokenStorage,
        feedback: any FeedbackPlayer,
        soloDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        urlSession: URLSession = .shared
    ) {
        self.settings = settings
        self.defaults = defaults
        let api = APIClient(baseURL: settings.serverURL, session: urlSession)
        self.api = api
        self.session = SessionStore(api: api, tokenStorage: tokenStorage, defaults: defaults)
        let online = OnlineGamesStore(api: api)
        self.online = online
        self.moderation = ModerationStore(api: api, online: online)
        self.solo = SoloGamesStore(directory: soloDirectory)
        self.feedback = feedback

        api.setUnauthorizedHandler { [weak self, api] in
            // This runs while the rejected token is still the current one.
            let rejectedToken = api.token
            Task { @MainActor in self?.sessionDidExpire(rejectedToken: rejectedToken) }
        }
    }

    var isSignedIn: Bool { session.isSignedIn }

    /// The server's privacy policy, which App Store Connect links to as well.
    var privacyPolicyURL: URL { settings.serverURL.appending(path: "privacy") }
    /// The server's support page.
    var supportURL: URL { settings.serverURL.appending(path: "support") }
    /// The terms players agree to by signing in, with zero tolerance for abuse (App Store guideline 1.2).
    var termsURL: URL { settings.serverURL.appending(path: "terms") }

    // MARK: Session

    func signIn(username: String, password: String) async throws {
        try await session.signIn(username: username, password: password)
        await sessionDidStart()
    }

    func register(username: String, password: String) async throws {
        try await session.register(username: username, password: password)
        await sessionDidStart()
    }

    func signInWithApple(_ request: AppleSignInRequest, appleUserID: String) async throws -> ExternalSignInOutcome {
        let outcome = try await session.signInWithApple(request, appleUserID: appleUserID)
        if outcome == .signedIn {
            await sessionDidStart()
        }
        return outcome
    }

    func signInWithGoogle(_ request: GoogleSignInRequest) async throws -> ExternalSignInOutcome {
        let outcome = try await session.signInWithGoogle(request)
        if outcome == .signedIn {
            await sessionDidStart()
        }
        return outcome
    }

    /// Finishes a first sign-in with Apple or Google by creating the account.
    func completeSignup(ticket: String, username: String) async throws {
        try await session.completeSignup(ticket: ticket, username: username)
        await sessionDidStart()
    }

    func signOut() async {
        await unregisterDevice()
        await session.signOut()
        forgetOnlineState()
    }

    /// Deletes the account on the server. Battles in progress are resigned.
    func deleteAccount() async throws {
        try await session.deleteAccount()
        forgetOnlineState()
    }

    /// The server turned the session down, or the player stopped using their Apple ID with the app.
    /// `rejectedToken` guards against a late answer about an earlier session ending this one.
    func sessionDidExpire(rejectedToken: String?) {
        guard session.isSignedIn, session.token == rejectedToken else { return }
        session.clear()
        forgetOnlineState()
        showsSessionExpired = true
    }

    /// Points the app at another server. Accounts belong to a server, so this signs out first.
    func changeServer(to url: URL) async {
        guard url != settings.serverURL else { return }
        await signOut()
        settings.serverURL = url
        api.baseURL = url
        await session.loadProviders()
    }

    private func sessionDidStart() async {
        online.connect()
        await online.refresh()
        await registerDeviceIfPossible()
    }

    private func forgetOnlineState() {
        online.reset()
        moderation.reset()
    }

    // MARK: App lifecycle

    func appDidBecomeActive() {
        Task {
            await session.revokePendingSessions()
        }
        guard session.isSignedIn else {
            // Ready for the sign-in screen, so its Apple and Google buttons don't pop in late.
            Task { await session.loadProviders() }
            return
        }
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

    /// The last token APNs gave this device. Kept so that signing out can unregister it even in a
    /// launch where the app didn't register for notifications.
    private var devicePushToken: String? {
        get { defaults.string(forKey: Self.devicePushTokenKey) }
        set { defaults.set(newValue, forKey: Self.devicePushTokenKey) }
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

    /// Stops this device getting the player's notifications. The server also drops the devices a
    /// session registered when that session ends, so this is a courtesy when signing out works.
    private func unregisterDevice() async {
        guard let devicePushToken, session.isSignedIn else { return }
        try? await api.unregisterDevice(token: devicePushToken)
    }
}
