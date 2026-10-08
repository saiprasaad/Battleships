import BattleshipAPI
import Vapor

/// `/v1/games`
struct GamesController: RouteCollection {
    let services: AppServices

    func boot(routes: any RoutesBuilder) throws {
        let games = routes.grouped("games")
        games.get(use: list)
        games.post(use: create)

        let game = games.grouped(":gameID")
        game.get(use: show)
        game.post("accept", use: accept)
        game.post("decline", use: decline)
        game.post("cancel", use: cancel)
        game.post("resign", use: resign)
        game.post("claim-victory", use: claimVictory)
        game.post("shots", use: fire)
    }

    @Sendable
    func list(req: Request) async throws -> [GameSummary] {
        try await services.games.games(for: req.auth.require(User.self), on: req.db)
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let request = try req.content.decode(CreateGameRequest.self)
        let detail = try await services.games.create(request, by: req.auth.require(User.self), on: req.db)
        return try await detail.encodeResponse(status: .created, for: req)
    }

    @Sendable
    func show(req: Request) async throws -> GameDetail {
        try await services.games.game(gameID(req), for: req.auth.require(User.self), on: req.db)
    }

    @Sendable
    func accept(req: Request) async throws -> GameDetail {
        let body = try req.content.decode(AcceptChallengeRequest.self)
        return try await services.games.accept(gameID(req), fleet: body.fleet, by: req.auth.require(User.self), on: req.db)
    }

    @Sendable
    func decline(req: Request) async throws -> HTTPStatus {
        try await services.games.decline(gameID(req), by: req.auth.require(User.self), on: req.db)
        return .noContent
    }

    @Sendable
    func cancel(req: Request) async throws -> HTTPStatus {
        try await services.games.cancel(gameID(req), by: req.auth.require(User.self), on: req.db)
        return .noContent
    }

    @Sendable
    func resign(req: Request) async throws -> GameDetail {
        try await services.games.resign(gameID(req), by: req.auth.require(User.self), on: req.db)
    }

    @Sendable
    func claimVictory(req: Request) async throws -> GameDetail {
        try await services.games.claimVictory(gameID(req), by: req.auth.require(User.self), on: req.db)
    }

    @Sendable
    func fire(req: Request) async throws -> FireResponse {
        let body = try req.content.decode(FireRequest.self)
        return try await services.games.fire(at: body.target, in: gameID(req), by: req.auth.require(User.self), on: req.db)
    }

    private func gameID(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("gameID", as: UUID.self) else { throw AppError.gameNotFound }
        return id
    }
}

/// `GET /v1/events`: a WebSocket that streams ``ServerEvent``s to the signed-in player.
struct EventsController: RouteCollection {
    let services: AppServices

    func boot(routes: any RoutesBuilder) throws {
        let hub = services.hub
        routes.get("events") { req async throws -> Response in
            let userID = try req.auth.require(User.self).requireID()
            let tokenID = req.auth.get(UserToken.self)?.id
            let response = Response(status: .switchingProtocols)
            response.upgrader = EventStreamUpgrader { socket, channel in
                // Pings detect connections that died without closing (e.g. a phone losing signal).
                socket.pingInterval = .seconds(25)
                Task {
                    await hub.register(socket, channel: channel, userID: userID, tokenID: tokenID)
                    socket.onClose.whenComplete { _ in
                        Task { await hub.unregister(socket, userID: userID) }
                    }
                }
            }
            return response
        }
    }
}
