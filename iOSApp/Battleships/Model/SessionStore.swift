import BattleshipAPI
import BattleshipClient
import Foundation
import Observation

/// Where the session token is kept between launches.
@MainActor
protocol TokenStorage: AnyObject {
    func loadToken() -> String?
    func saveToken(_ token: String?)
}

/// Keeps the token in memory only. Used by tests and previews.
@MainActor
final class InMemoryTokenStorage: TokenStorage {
    private var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func loadToken() -> String? { token }
    func saveToken(_ token: String?) { self.token = token }
}

/// The signed-in player, if any. The token lives in the keychain; the account is cached so the
/// profile shows instantly on launch and is refreshed from the server in the background.
@MainActor
@Observable
final class SessionStore {
    private static let accountKey = "cachedAccount"

    private(set) var account: Account?
    private(set) var token: String?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let tokenStorage: any TokenStorage
    @ObservationIgnored private let defaults: UserDefaults

    init(api: APIClient, tokenStorage: any TokenStorage, defaults: UserDefaults = .standard) {
        self.api = api
        self.tokenStorage = tokenStorage
        self.defaults = defaults

        let token = tokenStorage.loadToken()
        self.token = token
        api.token = token
        if token != nil, let data = defaults.data(forKey: Self.accountKey) {
            account = try? APICoding.makeDecoder().decode(Account.self, from: data)
        }
    }

    var isSignedIn: Bool { token != nil }

    func register(username: String, password: String) async throws {
        let response = try await api.register(Credentials(username: username, password: password))
        begin(response)
    }

    func signIn(username: String, password: String) async throws {
        let response = try await api.signIn(Credentials(username: username, password: password))
        begin(response)
    }

    /// Re-fetches rating and record. Failures are ignored; the cached account stays on screen.
    func refreshAccount() async {
        guard isSignedIn, let account = try? await api.account() else { return }
        remember(account)
    }

    /// Ends the session on the server (best effort) and forgets it locally.
    func signOut() async {
        if isSignedIn {
            try? await api.signOut()
        }
        clear()
    }

    func deleteAccount() async throws {
        try await api.deleteAccount()
        clear()
    }

    /// Forgets the session locally, e.g. after the server rejected the token.
    func clear() {
        token = nil
        account = nil
        api.token = nil
        tokenStorage.saveToken(nil)
        defaults.removeObject(forKey: Self.accountKey)
    }

    private func begin(_ response: AuthResponse) {
        token = response.token
        api.token = response.token
        tokenStorage.saveToken(response.token)
        remember(response.account)
    }

    private func remember(_ account: Account) {
        self.account = account
        if let data = try? APICoding.makeEncoder().encode(account) {
            defaults.set(data, forKey: Self.accountKey)
        }
    }
}
