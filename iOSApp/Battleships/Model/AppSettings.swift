import Foundation
import Observation

/// User preferences, persisted in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let serverURL = "serverURL"
        static let haptics = "hapticsEnabled"
        static let askedForNotifications = "askedForNotifications"
        static let seenWelcome = "hasSeenWelcome"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The server configured at build time (`API_BASE_URL` in Config/Battleships.xcconfig).
    let defaultServerURL: URL

    /// The server the app talks to. Accounts belong to a server, so changing it signs you out.
    var serverURL: URL {
        didSet { defaults.set(serverURL.absoluteString, forKey: Keys.serverURL) }
    }

    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Keys.haptics) }
    }

    /// Whether the app has already asked for permission to send notifications.
    var hasAskedForNotifications: Bool {
        didSet { defaults.set(hasAskedForNotifications, forKey: Keys.askedForNotifications) }
    }

    /// Whether the player has been through the welcome screen shown on first launch.
    var hasSeenWelcome: Bool {
        didSet { defaults.set(hasSeenWelcome, forKey: Keys.seenWelcome) }
    }

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        let configured = (bundle.object(forInfoDictionaryKey: "BattleshipsAPIBaseURL") as? String)
            .flatMap(Self.validatedServerURL)
        defaultServerURL = configured ?? URL(string: "http://localhost:8080")!
        serverURL = defaults.string(forKey: Keys.serverURL).flatMap(Self.validatedServerURL) ?? defaultServerURL
        hapticsEnabled = defaults.object(forKey: Keys.haptics) as? Bool ?? true
        hasAskedForNotifications = defaults.bool(forKey: Keys.askedForNotifications)
        hasSeenWelcome = defaults.bool(forKey: Keys.seenWelcome)
    }

    /// Parses a server address typed by the user. Accepts `http` and `https` URLs with a host.
    nonisolated static func validatedServerURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
