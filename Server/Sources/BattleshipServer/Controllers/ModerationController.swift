import BattleshipAPI
import Fluent
import Vapor

/// Blocking and reporting players (App Store guideline 1.2: apps with user-generated content, here
/// usernames, let people report offensive content and block abusive users).
struct ModerationController: RouteCollection {
    let services: AppServices

    func boot(routes: any RoutesBuilder) throws {
        routes.get("me", "blocked", use: blockedPlayers)
        let player = routes.grouped("players", ":playerID")
        player.put("block", use: block)
        player.delete("block", use: unblock)
        player.post("report", use: report)
    }

    @Sendable
    func blockedPlayers(req: Request) async throws -> [PlayerSummary] {
        let user = try req.auth.require(User.self)
        let blocks = try await Block.query(on: req.db)
            .filter(\.$blocker.$id == user.requireID())
            .with(\.$blocked)
            .sort(\.$createdAt, .descending)
            .all()
        return try blocks.map { try $0.blocked.summary() }
    }

    @Sendable
    func block(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        try await services.games.block(try playerID(in: req), by: user, on: req.db)
        return .noContent
    }

    @Sendable
    func unblock(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        try await services.games.unblock(try playerID(in: req), by: user, on: req.db)
        return .noContent
    }

    @Sendable
    func report(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let reporterID = try user.requireID()
        let reportedID = try playerID(in: req)
        let request = try req.content.decode(ReportPlayerRequest.self)
        guard reportedID != reporterID else { throw AppError.cannotBlockYourself }

        let db = req.db
        let reported = try await services.writeLock.withLock { () -> User in
            guard let reported = try await User.find(reportedID, on: db) else { throw AppError.playerNotFound }
            // One open report per pair of players: reporting again updates it rather than piling up.
            if let existing = try await Report.query(on: db)
                .filter(\.$reporter.$id == reporterID)
                .filter(\.$reported.$id == reportedID)
                .first() {
                existing.reason = request.reason.rawValue
                existing.gameID = request.gameID ?? existing.gameID
                try await existing.save(on: db)
            } else {
                try await Report(reporterID: reporterID, reportedID: reportedID, reason: request.reason, gameID: request.gameID).save(on: db)
            }
            return reported
        }
        req.logger.warning("Player reported", metadata: [
            "reported": "\(reported.username)",
            "reason": "\(request.reason.rawValue)",
        ])
        return .noContent
    }

    private func playerID(in req: Request) throws -> UUID {
        guard let id = req.parameters.get("playerID", as: UUID.self) else { throw AppError.playerNotFound }
        return id
    }
}

/// Tools for whoever runs the server, under `/v1/admin`, enabled by setting `ADMIN_TOKEN`:
///
///     curl -H "Authorization: Bearer $ADMIN_TOKEN" https://your-server/v1/admin/reports
struct AdminController: RouteCollection {
    struct ReportEntry: Content {
        let id: UUID
        let reported: PlayerSummary
        let reportedBy: String?
        let reason: ReportReason
        let gameID: UUID?
        let createdAt: Date?
    }

    let services: AppServices
    let token: String

    func boot(routes: any RoutesBuilder) throws {
        let admin = routes.grouped("admin").grouped(AdminTokenMiddleware(token: token))
        admin.get("reports", use: reports)
        admin.delete("reports", ":reportID", use: dismissReport)
        admin.delete("players", ":playerID", use: deletePlayer)
    }

    /// Open reports, newest first.
    @Sendable
    func reports(req: Request) async throws -> [ReportEntry] {
        let reports = try await Report.query(on: req.db)
            .with(\.$reporter)
            .with(\.$reported)
            .sort(\.$createdAt, .descending)
            .limit(500)
            .all()
        return try reports.map { report in
            ReportEntry(
                id: try report.requireID(),
                reported: try report.reported.summary(),
                reportedBy: report.reporter?.username,
                reason: ReportReason(rawValue: report.reason) ?? .other,
                gameID: report.gameID,
                createdAt: report.createdAt
            )
        }
    }

    /// Closes a report once it's been dealt with.
    @Sendable
    func dismissReport(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("reportID", as: UUID.self) else { throw Abort(.notFound) }
        let db = req.db
        try await services.writeLock.withLock {
            try await Report.query(on: db).filter(\.$id == id).delete()
        }
        return .noContent
    }

    /// Removes a player's account, exactly as if they'd deleted it themselves.
    @Sendable
    func deletePlayer(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("playerID", as: UUID.self),
              let player = try await User.find(id, on: req.db)
        else { throw AppError.playerNotFound }
        try await services.games.deleteAccount(of: player, on: req.db)
        req.logger.notice("Account removed by an administrator", metadata: ["username": "\(player.username)"])
        return .noContent
    }
}

/// Lets through requests carrying the admin token.
struct AdminTokenMiddleware: AsyncMiddleware {
    let token: String

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Compare digests so the comparison takes the same time however much of the token matches.
        guard let presented = request.headers.bearerAuthorization?.token,
              SHA256.hash(data: Data(presented.utf8)) == SHA256.hash(data: Data(token.utf8))
        else { throw AppError.unauthorized }
        return try await next.respond(to: request)
    }
}
