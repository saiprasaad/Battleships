import Foundation
import Observation

/// User preferences, persisted in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let serverURL = "serverURL"
        static let haptics = "hapticsEnabled"
        static let sound = "soundEnabled"
        static let askedForNotifications = "askedForNotifications"
        static let seenWelcome = "hasSeenWelcome"
        static let seenOutcomes = "seenOutcomes"
    }

    /// How many finished games are remembered as having had their result shown.
    static let seenOutcomesKept = 300

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

    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.sound) }
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
        soundEnabled = defaults.object(forKey: Keys.sound) as? Bool ?? true
        hasAskedForNotifications = defaults.bool(forKey: Keys.askedForNotifications)
        hasSeenWelcome = defaults.bool(forKey: Keys.seenWelcome)
    }

    // MARK: Results the player has seen

    /// Whether the end of this game has already been shown, so opening it again doesn't replay it.
    func hasSeenOutcome(of gameID: UUID) -> Bool {
        defaults.stringArray(forKey: Keys.seenOutcomes)?.contains(gameID.uuidString) == true
    }

    func markOutcomeSeen(of gameID: UUID) {
        var seen = defaults.stringArray(forKey: Keys.seenOutcomes) ?? []
        guard !seen.contains(gameID.uuidString) else { return }
        seen.append(gameID.uuidString)
        defaults.set(Array(seen.suffix(Self.seenOutcomesKept)), forKey: Keys.seenOutcomes)
    }

    // MARK: Server addresses

    /// Parses a server address typed by the user: an `https` URL, or `http` for a server on the
    /// local network, the only place iOS allows unencrypted connections to.
    nonisolated static func validatedServerURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              scheme == "https" || isLocalNetworkHost(host)
        else { return nil }
        components.scheme = scheme
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Why `text` isn't a usable server address, to show under the field. `nil` if it's fine (or empty).
    nonisolated static func serverAddressProblem(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, validatedServerURL(trimmed) == nil else { return nil }
        if let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "http",
           let host = components.host, !host.isEmpty {
            return "Use https://. Plain http:// only works with a server on your local network."
        }
        return "Enter the server's address, starting with https://."
    }

    /// Hosts that App Transport Security treats as local: `localhost`, names without a dot,
    /// `.local` names, and IP addresses.
    nonisolated static func isLocalNetworkHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || !host.contains(".") || host.hasSuffix(".local") || host.contains(":") {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { UInt8($0) != nil }
    }
}
