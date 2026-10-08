import BattleshipAPI
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

    var port: Int?
    var database: DatabaseLocation
    var apns: APNSCredentials?
    /// Sign-in and registration attempts allowed per client IP per minute.
    var authRequestsPerMinute: Int
    /// Games a player can have in progress (or waiting) at once.
    var maxOpenGamesPerPlayer: Int
    /// How many finished games the lobby lists.
    var finishedGamesInLobby: Int
    var sessionLifetime: TimeInterval
    var bcryptCost: Int
    /// How long a player has to make their move before the opponent can claim the win.
    var turnTimeLimit: TimeInterval

    static func load(for environment: Environment) throws -> ServerSettings {
        let testing = environment == .testing

        let database: DatabaseLocation
        if let url = Environment.get("DATABASE_URL"), !url.isEmpty {
            database = .postgres(url: url)
        } else if testing {
            database = .sqliteInMemory
        } else {
            database = .sqliteFile(path: Environment.get("SQLITE_PATH") ?? "battleships.sqlite")
        }

        var apns: APNSCredentials?
        if let keyID = Environment.get("APNS_KEY_ID"),
           let teamID = Environment.get("APNS_TEAM_ID"),
           let topic = Environment.get("APNS_TOPIC") {
            let pem: String? = if let inline = Environment.get("APNS_PRIVATE_KEY") {
                // Platforms that store secrets on one line usually escape newlines.
                inline.replacingOccurrences(of: "\\n", with: "\n")
            } else if let path = Environment.get("APNS_PRIVATE_KEY_PATH") {
                try String(contentsOfFile: path, encoding: .utf8)
            } else {
                nil
            }
            if let pem {
                apns = APNSCredentials(keyID: keyID, teamID: teamID, privateKeyPEM: pem, topic: topic)
            }
        }

        return ServerSettings(
            port: Environment.get("PORT").flatMap(Int.init),
            database: database,
            apns: apns,
            authRequestsPerMinute: Environment.get("AUTH_RATE_LIMIT_PER_MINUTE").flatMap(Int.init) ?? (testing ? 10_000 : 20),
            maxOpenGamesPerPlayer: Environment.get("MAX_OPEN_GAMES").flatMap(Int.init) ?? 20,
            finishedGamesInLobby: 25,
            sessionLifetime: 60 * 60 * 24 * 90,
            bcryptCost: testing ? 4 : 12,
            turnTimeLimit: 60 * 60 * (Environment.get("TURN_TIME_LIMIT_HOURS").flatMap(Double.init) ?? 72)
        )
    }
}
