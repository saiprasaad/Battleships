import BattleshipAPI
import JWTKit
import Vapor

/// Runtime configuration, read from environment variables (see the README for the full list).
struct ServerSettings: Sendable {
    enum DatabaseLocation: Sendable, Equatable {
        case postgres(url: String)
        case sqliteFile(path: String)
        case sqliteInMemory
    }

    struct APNSCredentials: Sendable {
        var keyID: String
        var teamID: String
        var privateKeyPEM: String
        /// The app's bundle identifier.
        var topic: String
    }

    /// Sign in with Apple.
    struct AppleSignIn: Sendable {
        /// The app's bundle identifier: the audience of the identity tokens Apple issues for it.
        var bundleID: String
        /// For exchanging authorization codes and revoking the app's access when an account is deleted.
        var key: AppleSignInKey?
    }

    /// A Sign in with Apple private key (a .p8 file from the developer account), which signs the
    /// client secret for Apple's token and revoke endpoints.
    struct AppleSignInKey: Sendable {
        var teamID: String
        var keyID: String
        var privateKeyPEM: String
    }

    /// Where the address of the player behind a request comes from, for rate limiting.
    enum ClientAddressSource: Sendable, Equatable {
        /// Whoever opened the TCP connection. Behind a proxy that's the proxy itself.
        case peer
        /// A header the hosting platform's proxy sets and clients can't forge, like `Fly-Client-IP`.
        case header(String)
        /// The address `trustedProxies` hops from the right of `X-Forwarded-For`. Each proxy appends
        /// the address it was connected from, so anything further left came from the client.
        case forwardedFor(trustedProxies: Int)
    }

    var port: Int?
    var database: DatabaseLocation
    var apns: APNSCredentials?
    var clientAddressSource: ClientAddressSource = .peer
    /// Sign-in and registration attempts allowed per client IP per minute.
    var authRequestsPerMinute: Int
    /// Sign-in attempts allowed per username per hour, wherever they come from.
    var loginAttemptsPerUsernamePerHour: Int = 10
    /// Games a player can have in progress (or waiting) at once.
    var maxOpenGamesPerPlayer: Int
    /// Games (challenges or matchmaking requests) a player can start per hour.
    var newGamesPerHour: Int = 30
    /// Unanswered challenges a player can have waiting for them at once.
    var maxPendingChallenges: Int = 20
    /// How many finished games the lobby lists.
    var finishedGamesInLobby: Int
    var sessionLifetime: TimeInterval
    var bcryptCost: Int
    /// How long a player has to make their move before the opponent can claim the win.
    var turnTimeLimit: TimeInterval
    /// Matchmaking only pairs a newcomer with a waiting player who queued, or was online, this recently
    /// (or is online now): the waiting player moves first, and may have given up long ago.
    var matchmakingFreshness: TimeInterval = 15 * 60
    /// Where players can reach the people running the server; shown on the privacy and support pages.
    var supportEmail: String?
    /// Unlocks the moderation endpoints under `/v1/admin` when set.
    var adminToken: String?
    /// Words usernames can't contain, on top of ``CredentialPolicy/blockedUsernameWords``.
    var extraBlockedUsernameWords: [String] = []
    var appleSignIn: AppleSignIn?
    /// The OAuth client ID of the Google Cloud "iOS" client: the audience of Google ID tokens for the app.
    var googleClientID: String?

    static let minimumAdminTokenLength = 16

    /// Reads the settings from the process environment.
    static func load(for environment: Environment) throws -> ServerSettings {
        try load(for: environment, from: ProcessInfo.processInfo.environment)
    }

    /// Reads the settings from `variables`, failing on the first invalid value so that a typo stops the
    /// server at startup instead of quietly changing how it behaves.
    static func load(for environment: Environment, from variables: [String: String]) throws -> ServerSettings {
        let testing = environment == .testing
        let env = SettingsReader(variables: variables)

        // Tests wipe their database, so they never touch DATABASE_URL.
        let databaseVariable = testing ? "TEST_DATABASE_URL" : "DATABASE_URL"
        let database: DatabaseLocation
        if let url = env.string(databaseVariable) {
            guard let scheme = URL(string: url)?.scheme?.lowercased(), ["postgres", "postgresql"].contains(scheme) else {
                throw ConfigurationError("\(databaseVariable) must be a postgres:// URL, like postgres://user:password@host:5432/database.")
            }
            database = .postgres(url: url)
        } else if testing {
            database = .sqliteInMemory
        } else {
            database = .sqliteFile(path: env.string("SQLITE_PATH") ?? "battleships.sqlite")
        }

        let clientAddressSource: ClientAddressSource
        let ipHeader = env.string("CLIENT_IP_HEADER")
        let trustedProxies = try env.integer("TRUSTED_PROXY_COUNT", default: 0, in: 0...10)
        switch (ipHeader, trustedProxies) {
        case let (header?, 0):
            guard header.utf8.allSatisfy(Self.isHeaderNameCharacter) else {
                throw ConfigurationError("CLIENT_IP_HEADER must be a header name, like Fly-Client-IP, but it's \"\(header)\".")
            }
            guard !["x-forwarded-for", "forwarded"].contains(header.lowercased()) else {
                throw ConfigurationError("CLIENT_IP_HEADER can't be \(header): clients can write to it. Set TRUSTED_PROXY_COUNT to the number of proxies in front of the server instead.")
            }
            clientAddressSource = .header(header)
        case (nil, 0):
            clientAddressSource = .peer
        case (nil, let count):
            clientAddressSource = .forwardedFor(trustedProxies: count)
        case (.some, _):
            throw ConfigurationError("Set CLIENT_IP_HEADER or TRUSTED_PROXY_COUNT, not both.")
        }

        let supportEmail = env.string("SUPPORT_EMAIL")
        if let supportEmail, !Self.looksLikeEmailAddress(supportEmail) {
            throw ConfigurationError("SUPPORT_EMAIL must be an email address, like support@example.com, but it's \"\(supportEmail)\".")
        }

        let adminToken = env.string("ADMIN_TOKEN")
        if let adminToken, adminToken.count < minimumAdminTokenLength {
            throw ConfigurationError("ADMIN_TOKEN must be at least \(minimumAdminTokenLength) characters. Generate one with: openssl rand -hex 32")
        }

        let turnTimeLimitHours = try env.number("TURN_TIME_LIMIT_HOURS", default: 72, greaterThan: 0, atMost: 24 * 365)

        let googleClientID = env.string("GOOGLE_IOS_CLIENT_ID")
        // The reversed form is the app's URL scheme, and an easy one to paste by mistake.
        if let googleClientID, !googleClientID.hasSuffix(".apps.googleusercontent.com") || googleClientID.contains(where: \.isWhitespace) {
            throw ConfigurationError("GOOGLE_IOS_CLIENT_ID must be the iOS client ID, ending in .apps.googleusercontent.com (not the reversed one the app uses as a URL scheme).")
        }

        return ServerSettings(
            port: try env.optionalInteger("PORT", in: 1...65_535),
            database: database,
            apns: try loadAPNS(from: env),
            clientAddressSource: clientAddressSource,
            authRequestsPerMinute: try env.integer("AUTH_RATE_LIMIT_PER_MINUTE", default: testing ? 10_000 : 20, in: 1...1_000_000),
            loginAttemptsPerUsernamePerHour: try env.integer("LOGIN_RATE_LIMIT_PER_USERNAME_PER_HOUR", default: 10, in: 1...1_000_000),
            maxOpenGamesPerPlayer: try env.integer("MAX_OPEN_GAMES", default: 20, in: 1...10_000),
            newGamesPerHour: try env.integer("NEW_GAME_RATE_LIMIT_PER_HOUR", default: 30, in: 1...1_000_000),
            maxPendingChallenges: try env.integer("MAX_PENDING_CHALLENGES", default: 20, in: 1...10_000),
            finishedGamesInLobby: 25,
            sessionLifetime: 60 * 60 * 24 * 90,
            bcryptCost: testing ? 4 : 12,
            turnTimeLimit: 60 * 60 * turnTimeLimitHours,
            supportEmail: supportEmail,
            adminToken: adminToken,
            extraBlockedUsernameWords: (env.string("BLOCKED_USERNAME_WORDS") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            appleSignIn: try loadAppleSignIn(from: env),
            googleClientID: googleClientID
        )
    }

    private static func loadAppleSignIn(from env: SettingsReader) throws -> AppleSignIn? {
        let bundleID = env.string("APPLE_BUNDLE_ID")
        let teamID = env.string("APPLE_TEAM_ID")
        let keyID = env.string("APPLE_SIGN_IN_KEY_ID")
        let pem = env.pem("APPLE_SIGN_IN_PRIVATE_KEY")

        let keyParts: [(name: String, value: String?)] = [
            ("APPLE_TEAM_ID", teamID), ("APPLE_SIGN_IN_KEY_ID", keyID), ("APPLE_SIGN_IN_PRIVATE_KEY", pem),
        ]
        let missing = keyParts.filter { $0.value == nil }.map(\.name)
        guard missing.isEmpty || missing.count == keyParts.count else {
            throw ConfigurationError("The Sign in with Apple key is only partly set up. Also set \(missing.joined(separator: ", ")), or unset the others.")
        }
        guard let bundleID else {
            if missing.isEmpty {
                throw ConfigurationError("APPLE_TEAM_ID, APPLE_SIGN_IN_KEY_ID and APPLE_SIGN_IN_PRIVATE_KEY need APPLE_BUNDLE_ID too.")
            }
            return nil
        }
        guard bundleID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            throw ConfigurationError("APPLE_BUNDLE_ID must be the app's bundle identifier, like com.example.battleships, but it's \"\(bundleID)\".")
        }

        guard let teamID, let keyID, let pem else {
            return AppleSignIn(bundleID: bundleID)
        }
        do {
            _ = try ES256PrivateKey(pem: pem)
        } catch {
            throw ConfigurationError("APPLE_SIGN_IN_PRIVATE_KEY must be the contents of the Sign in with Apple key's .p8 file.")
        }
        return AppleSignIn(bundleID: bundleID, key: AppleSignInKey(teamID: teamID, keyID: keyID, privateKeyPEM: pem))
    }

    /// Push is optional, but half a configuration is a mistake worth stopping for.
    private static func loadAPNS(from env: SettingsReader) throws -> APNSCredentials? {
        let keyID = env.string("APNS_KEY_ID")
        let teamID = env.string("APNS_TEAM_ID")
        let topic = env.string("APNS_TOPIC")
        let inlineKey = env.pem("APNS_PRIVATE_KEY")
        let keyPath = env.string("APNS_PRIVATE_KEY_PATH")
        guard keyID != nil || teamID != nil || topic != nil || inlineKey != nil || keyPath != nil else { return nil }

        let pem = try inlineKey ?? keyPath.map { try env.contentsOfFile(named: "APNS_PRIVATE_KEY_PATH", at: $0) }

        var missing: [String] = []
        if keyID == nil { missing.append("APNS_KEY_ID") }
        if teamID == nil { missing.append("APNS_TEAM_ID") }
        if topic == nil { missing.append("APNS_TOPIC") }
        if pem == nil { missing.append("APNS_PRIVATE_KEY (or APNS_PRIVATE_KEY_PATH)") }
        guard let keyID, let teamID, let topic, let pem else {
            throw ConfigurationError("Push notifications are only partly set up. Also set \(missing.joined(separator: ", ")), or unset the APNS_ variables.")
        }
        return APNSCredentials(keyID: keyID, teamID: teamID, privateKeyPEM: pem, topic: topic)
    }

    private static func isHeaderNameCharacter(_ byte: UInt8) -> Bool {
        // RFC 9110 "token" characters.
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        default:
            "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    private static func looksLikeEmailAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            && !text.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) || "<>\"".unicodeScalars.contains($0) }
    }
}

/// Why the server can't start with the environment it was given.
struct ConfigurationError: DebuggableError, Equatable {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }

    var identifier: String { "invalidConfiguration" }
    var logLevel: Logger.Level { .critical }
}

/// Typed access to environment variables. Empty values count as unset, since some platforms can only
/// blank a variable rather than remove it.
struct SettingsReader {
    let variables: [String: String]

    func string(_ name: String) -> String? {
        guard let value = variables[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    func optionalInteger(_ name: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let text = string(name) else { return nil }
        guard let value = Int(text), range.contains(value) else {
            throw ConfigurationError("\(name) must be a whole number from \(range.lowerBound) to \(range.upperBound), but it's \"\(text)\".")
        }
        return value
    }

    func integer(_ name: String, default defaultValue: Int, in range: ClosedRange<Int>) throws -> Int {
        try optionalInteger(name, in: range) ?? defaultValue
    }

    func number(_ name: String, default defaultValue: Double, greaterThan minimum: Double, atMost maximum: Double) throws -> Double {
        guard let text = string(name) else { return defaultValue }
        guard let value = Double(text), value.isFinite, value > minimum, value <= maximum else {
            throw ConfigurationError("\(name) must be a number greater than \(String(format: "%g", minimum)) and at most \(String(format: "%g", maximum)), but it's \"\(text)\".")
        }
        return value
    }

    /// A PEM file's contents given inline. Platforms that store secrets on one line usually escape newlines.
    func pem(_ name: String) -> String? {
        string(name)?.replacingOccurrences(of: "\\n", with: "\n")
    }

    func contentsOfFile(named name: String, at path: String) throws -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ConfigurationError("Can't read \(name) (\(path)): \(error.localizedDescription)")
        }
    }
}
