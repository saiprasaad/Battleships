import BattleshipAPI
import Fluent
import FluentSQL
import Vapor

/// `/v1/me`: the signed-in account.
struct AccountController: RouteCollection {
    let services: AppServices

    func boot(routes: any RoutesBuilder) throws {
        let me = routes.grouped("me")
        me.get(use: account)
        me.delete(use: deleteAccount)
    }

    @Sendable
    func account(req: Request) async throws -> Account {
        try req.auth.require(User.self).account()
    }

    /// Required by App Store guideline 5.1.1(v): accounts can be deleted from inside the app.
    @Sendable
    func deleteAccount(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        try await services.games.deleteAccount(of: user, on: req.db)
        return .noContent
    }
}

/// Player search (for challenges) and the leaderboard.
struct PlayersController: RouteCollection {
    static let leaderboardSize = 50
    static let searchLimit = 10

    func boot(routes: any RoutesBuilder) throws {
        routes.get("players", use: search)
        routes.get("leaderboard", use: leaderboard)
    }

    @Sendable
    func search(req: Request) async throws -> [PlayerSummary] {
        let user = try req.auth.require(User.self)
        let prefix = CredentialPolicy.normalized((try? req.query.get(String.self, at: "prefix")) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Usernames only contain letters, digits and underscores; anything else can't match.
        guard !prefix.isEmpty, prefix.count <= CredentialPolicy.usernameLength.upperBound,
              prefix.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") })
        else { return [] }

        // "_" is a wildcard in LIKE, so escape it: only real prefixes match, on SQLite and Postgres
        // alike, and whatever the database's collation.
        let pattern = prefix.replacingOccurrences(of: "_", with: "!_") + "%"
        let userID = try user.requireID()
        var query = User.query(on: req.db)
            .filter(.sql(embed: "\(SQLColumn("username_key", table: User.schema)) LIKE \(bind: pattern) ESCAPE '!'"))
            .filter(\.$id != userID)
        let blocked = try await Block.counterparts(of: userID, on: req.db)
        if !blocked.isEmpty {
            query = query.filter(\.$id !~ blocked)
        }
        // The final order is decided here, byte by byte: a database collation may ignore the "_"
        // (Postgres in an English locale does), and results should be the same on any database.
        let matches = try await query
            .sort(\.$usernameKey)
            .limit(Self.searchLimit * 5)
            .all()
        return try matches
            .sorted { $0.usernameKey.utf8.lexicographicallyPrecedes($1.usernameKey.utf8) }
            .prefix(Self.searchLimit)
            .map { try $0.summary() }
    }

    @Sendable
    func leaderboard(req: Request) async throws -> [LeaderboardEntry] {
        let players = try await User.query(on: req.db)
            .group(.or) { $0.filter(\.$wins > 0).filter(\.$losses > 0) }
            .sort(\.$rating, .descending)
            .sort(\.$wins, .descending)
            .sort(\.$usernameKey)
            .limit(Self.leaderboardSize)
            .all()

        // Standard competition ranking: equal ratings share a rank ("1, 2, 2, 4").
        var entries: [LeaderboardEntry] = []
        for (index, player) in players.enumerated() {
            let rank = index > 0 && player.rating == players[index - 1].rating ? entries[index - 1].rank : index + 1
            entries.append(LeaderboardEntry(rank: rank, player: try player.summary(), wins: player.wins, losses: player.losses))
        }
        return entries
    }
}

/// `/v1/devices`: APNs device tokens for push notifications.
struct DevicesController: RouteCollection {
    let services: AppServices

    func boot(routes: any RoutesBuilder) throws {
        let devices = routes.grouped("devices")
        devices.post(use: register)
        devices.delete(":token", use: unregister)
    }

    /// Devices per player. Registering another forgets the one registered longest ago.
    static let maxDevicesPerPlayer = 10

    @Sendable
    func register(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let registration = try req.content.decode(DeviceRegistration.self)
        let token = registration.token.lowercased()
        guard (32...256).contains(token.count), token.allSatisfy(\.isHexDigit) else {
            throw AppError.badRequest("That isn't a valid device token.")
        }

        let userID = try user.requireID()
        let sessionID = req.auth.get(UserToken.self)?.id
        let db = req.db
        try await services.writeLock.withLock {
            // A device belongs to whoever signed in on it most recently, through that session.
            let device = try await Device.query(on: db).filter(\.$token == token).first() ?? Device()
            device.$user.id = userID
            device.$session.id = sessionID
            device.token = token
            device.environment = registration.environment.rawValue
            // Saved even when nothing changed, so `updatedAt` records the latest registration.
            device.updatedAt = Date()
            try await device.save(on: db)

            let stale = try await Device.query(on: db)
                .filter(\.$user.$id == userID)
                .sort(\.$updatedAt, .descending)
                .all(\.$id)
                .dropFirst(Self.maxDevicesPerPlayer)
            if !stale.isEmpty {
                try await Device.query(on: db).filter(\.$id ~~ stale).delete()
            }
        }
        return .noContent
    }

    @Sendable
    func unregister(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let token = (req.parameters.get("token") ?? "").lowercased()
        let userID = try user.requireID()
        let db = req.db
        try await services.writeLock.withLock {
            try await Device.query(on: db)
                .filter(\.$token == token)
                .filter(\.$user.$id == userID)
                .delete()
        }
        return .noContent
    }
}
