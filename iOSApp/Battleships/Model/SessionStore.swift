import BattleshipAPI
import BattleshipClient
import Foundation
import Observation

/// Where the session token is kept between launches.
@MainActor
protocol TokenStorage: AnyObject {
    func loadToken() -> String?
    func saveToken(_ token: String?)
    /// Sessions that ended on this device but couldn't be revoked on the server yet, e.g. because
    /// the player signed out while offline.
    func loadPendingRevocations() -> [String]
    func savePendingRevocations(_ tokens: [String])
}

/// Keeps the token in memory only. Used by tests and previews.
@MainActor
final class InMemoryTokenStorage: TokenStorage {
    private var token: String?
    private var pendingRevocations: [String] = []

    init(token: String? = nil) {
        self.token = token
    }

    func loadToken() -> String? { token }
    func saveToken(_ token: String?) { self.token = token }
    func loadPendingRevocations() -> [String] { pendingRevocations }
    func savePendingRevocations(_ tokens: [String]) { pendingRevocations = tokens }
}

/// What came of signing in with Apple or Google.
enum ExternalSignInOutcome: Equatable, Sendable {
    case signedIn
    /// The first time with this Apple or Google account: the player picks a username to finish.
    case needsUsername(ticket: String, suggestion: String?)
}

/// The signed-in player, if any. The token lives in the keychain; the account is cached so the
/// profile shows instantly on launch and is refreshed from the server in the background.
@MainActor
@Observable
final class SessionStore {
    private static let accountKey = "cachedAccount"
    private static let appleUserIDKey = "appleUserID"
    /// Revocations are retried for a while, not forever.
    static let pendingRevocationLimit = 10

    private(set) var account: Account?
    private(set) var token: String?
    /// The sign-in methods the server offers besides a username and password.
    private(set) var providers: AuthProviders = .none
    /// The Apple ID behind this session, if the player signed in with Apple. If they stop using
    /// their Apple ID with the app, the app signs out.
    private(set) var appleUserID: String?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let tokenStorage: any TokenStorage
    @ObservationIgnored private let defaults: UserDefaults
    /// The Apple ID used for a sign-in that is waiting for a username.
    @ObservationIgnored private var pendingAppleUserID: String?

    init(api: APIClient, tokenStorage: any TokenStorage, defaults: UserDefaults = .standard) {
        self.api = api
        self.tokenStorage = tokenStorage
        self.defaults = defaults

        var token = tokenStorage.loadToken()
        let cachedAccount = defaults.data(forKey: Self.accountKey)
        if let orphan = token, cachedAccount == nil {
            // The keychain survives deleting the app; its settings don't. A token without them is
            // left over from an earlier install (maybe for another server), so start signed out
            // and end that session.
            Self.addPendingRevocation(orphan, to: tokenStorage)
            tokenStorage.saveToken(nil)
            token = nil
        }
        self.token = token
        api.token = token
        if token != nil, let cachedAccount {
            account = try? APICoding.makeDecoder().decode(Account.self, from: cachedAccount)
            appleUserID = defaults.string(forKey: Self.appleUserIDKey)
        }
    }

    var isSignedIn: Bool { token != nil }

    func register(username: String, password: String) async throws {
        let response = try await api.register(Credentials(username: username, password: password))
        begin(response, appleUserID: nil)
    }

    func signIn(username: String, password: String) async throws {
        let response = try await api.signIn(Credentials(username: username, password: password))
        begin(response, appleUserID: nil)
    }

    // MARK: Apple and Google

    /// Asks the server which other ways of signing in it supports. Failures leave the last answer.
    func loadProviders() async {
        if let providers = try? await api.authProviders() {
            self.providers = providers
        }
    }

    func signInWithApple(_ request: AppleSignInRequest, appleUserID: String) async throws -> ExternalSignInOutcome {
        let response = try await api.signInWithApple(request)
        return finish(response, appleUserID: appleUserID)
    }

    func signInWithGoogle(_ request: GoogleSignInRequest) async throws -> ExternalSignInOutcome {
        let response = try await api.signInWithGoogle(request)
        return finish(response, appleUserID: nil)
    }

    /// Creates the account for a first sign-in with Apple or Google.
    func completeSignup(ticket: String, username: String) async throws {
        let response = try await api.completeSignup(CompleteSignupRequest(signupTicket: ticket, username: username))
        begin(response, appleUserID: pendingAppleUserID)
    }

    private func finish(_ response: ExternalSignInResponse, appleUserID: String?) -> ExternalSignInOutcome {
        if let session = response.session {
            begin(session, appleUserID: appleUserID)
            return .signedIn
        }
        pendingAppleUserID = appleUserID
        return .needsUsername(ticket: response.signupTicket ?? "", suggestion: response.suggestedUsername)
    }

    // MARK: The session

    /// Re-fetches rating and record. Failures are ignored; the cached account stays on screen.
    func refreshAccount() async {
        guard let token, let account = try? await api.account(),
              self.token == token // still the same session once the answer arrives
        else { return }
        remember(account)
    }

    /// Ends the session on the server and forgets it locally. If the server can't be reached, the
    /// session is revoked the next time it can (see ``revokePendingSessions()``).
    func signOut() async {
        if let token {
            do {
                try await api.signOut()
            } catch let error as APIError where error.code == .unauthorized {
                // The server had already ended it.
            } catch {
                Self.addPendingRevocation(token, to: tokenStorage)
            }
        }
        clear()
    }

    /// Ends sessions that couldn't be revoked when the player signed out.
    func revokePendingSessions() async {
        let pending = tokenStorage.loadPendingRevocations()
        guard !pending.isEmpty else { return }
        var finished = Set<String>()
        for token in pending {
            do {
                try await api.signOut(token: token)
                finished.insert(token)
            } catch let error as APIError where error.code == .unauthorized {
                finished.insert(token)
            } catch {
                break // Still offline; try again later.
            }
        }
        // Reload in case a sign-out added one in the meantime.
        tokenStorage.savePendingRevocations(tokenStorage.loadPendingRevocations().filter { !finished.contains($0) })
    }

    func deleteAccount() async throws {
        try await api.deleteAccount()
        clear()
    }

    /// Forgets the session locally, e.g. after the server rejected the token.
    func clear() {
        token = nil
        account = nil
        appleUserID = nil
        pendingAppleUserID = nil
        api.token = nil
        tokenStorage.saveToken(nil)
        defaults.removeObject(forKey: Self.accountKey)
        defaults.removeObject(forKey: Self.appleUserIDKey)
    }

    private func begin(_ response: AuthResponse, appleUserID: String?) {
        token = response.token
        api.token = response.token
        tokenStorage.saveToken(response.token)
        self.appleUserID = appleUserID
        pendingAppleUserID = nil
        if let appleUserID {
            defaults.set(appleUserID, forKey: Self.appleUserIDKey)
        } else {
            defaults.removeObject(forKey: Self.appleUserIDKey)
        }
        remember(response.account)
    }

    private func remember(_ account: Account) {
        self.account = account
        if let data = try? APICoding.makeEncoder().encode(account) {
            defaults.set(data, forKey: Self.accountKey)
        }
    }

    private static func addPendingRevocation(_ token: String, to storage: any TokenStorage) {
        var pending = storage.loadPendingRevocations().filter { $0 != token }
        pending.append(token)
        storage.savePendingRevocations(Array(pending.suffix(pendingRevocationLimit)))
    }
}
