import BattleshipAPI
import BattleshipCore
import Fluent
import Vapor

/// All game logic: matchmaking, challenges, firing, resigning and results.
///
/// Every change runs under the shared write lock, so two requests can never act on the same game
/// (or grab the same matchmaking opponent) at once. Players are told about changes only after
/// they are committed, in commit order.
struct GameService: Sendable {
    let settings: ServerSettings
    let writeLock: AsyncLock
    let notifier: Notifier

    // MARK: Reading

    /// The player's unfinished games plus their most recent finished ones, newest activity first.
    func games(for user: User, on db: any Database) async throws -> [GameSummary] {
        let userID = try user.requireID()
        let unfinished = try await participating(userID, on: db)
            .filter(\.$statusRaw != GameStatus.finished.rawValue)
            .sort(\.$updatedAt, .descending)
            .all()
        let finished = try await participating(userID, on: db)
            .filter(\.$statusRaw == GameStatus.finished.rawValue)
            .sort(\.$updatedAt, .descending)
            .limit(settings.finishedGamesInLobby)
            .all()
        return try (unfinished + finished).compactMap { game in
            guard let seat = game.seat(of: userID) else { return nil }
            return try notifier.presenter.summary(of: game, for: seat)
        }
    }

    func game(_ gameID: UUID, for user: User, on db: any Database) async throws -> GameDetail {
        let (game, seat) = try await load(gameID, for: user, on: db)
        return try notifier.presenter.detail(of: game, for: seat)
    }

    // MARK: Starting games

    /// Challenges `request.opponent` by username, or joins matchmaking when no opponent is named.
    func create(_ request: CreateGameRequest, by user: User, on db: any Database) async throws -> GameDetail {
        try validate(request.fleet, for: request.mode)
        let opponentName = request.opponent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return try await writeLock.withLock {
            try await enforceOpenGameLimit(for: user, on: db)
            if opponentName.isEmpty {
                return try await matchmake(mode: request.mode, fleet: request.fleet, by: user, on: db)
            }
            return try await challenge(opponentName, mode: request.mode, fleet: request.fleet, by: user, on: db)
        }
    }

    private func challenge(
        _ opponentName: String,
        mode: GameMode,
        fleet: [ShipPlacement],
        by user: User,
        on db: any Database
    ) async throws -> GameDetail {
        guard let opponent = try await User.query(on: db)
            .filter(\.$usernameKey == CredentialPolicy.normalized(opponentName))
            .first()
        else { throw AppError.playerNotFound }
        guard opponent.id != user.id else { throw AppError.cannotChallengeYourself }

        let game = GameRecord(
            mode: mode,
            status: .invited,
            playerOneID: try user.requireID(),
            playerTwoID: try opponent.requireID(),
            fleetOne: fleet
        )
        try await game.save(on: db)
        game.$playerOne.value = user
        game.$playerTwo.value = opponent

        await notifier.broadcast(game)
        notifier.push(.challenge(from: user.username, mode: mode, gameID: try game.requireID()), to: opponent.id)
        return try notifier.presenter.detail(of: game, for: .one)
    }

    private func matchmake(mode: GameMode, fleet: [ShipPlacement], by user: User, on db: any Database) async throws -> GameDetail {
        let userID = try user.requireID()

        // Pair with whoever has been waiting longest for this mode.
        if let game = try await GameRecord.query(on: db)
            .filter(\.$statusRaw == GameStatus.matchmaking.rawValue)
            .filter(\.$modeRaw == mode.rawValue)
            .filter(\.$playerOne.$id != userID)
            .sort(\.$createdAt, .ascending)
            .with(\.$playerOne)
            .first() {
            game.$playerTwo.id = userID
            game.fleetTwo = fleet
            game.status = .active
            game.turn = Player.one.rawValue
            try await game.save(on: db)
            game.$playerTwo.value = user

            await notifier.broadcast(game)
            notifier.push(.opponentFound(user.username, gameID: try game.requireID()), to: game.userID(at: .one))
            return try notifier.presenter.detail(of: game, for: .two)
        }

        let game = GameRecord(mode: mode, status: .matchmaking, playerOneID: userID, playerTwoID: nil, fleetOne: fleet)
        try await game.save(on: db)
        game.$playerOne.value = user
        game.$playerTwo.value = .some(nil)
        await notifier.broadcast(game)
        return try notifier.presenter.detail(of: game, for: .one)
    }

    // MARK: Answering challenges

    func accept(_ gameID: UUID, fleet: [ShipPlacement], by user: User, on db: any Database) async throws -> GameDetail {
        try await writeLock.withLock {
            let (game, seat) = try await load(gameID, for: user, on: db)
            guard game.status == .invited, seat == .two else {
                throw AppError.invalidState("There's no challenge here for you to accept.")
            }
            try validate(fleet, for: game.mode)

            game.fleetTwo = fleet
            game.status = .active
            game.turn = Player.one.rawValue
            try await game.save(on: db)

            await notifier.broadcast(game)
            notifier.push(.challengeAccepted(by: user.username, gameID: gameID), to: game.userID(at: .one))
            return try notifier.presenter.detail(of: game, for: .two)
        }
    }

    func decline(_ gameID: UUID, by user: User, on db: any Database) async throws {
        try await writeLock.withLock {
            let (game, seat) = try await load(gameID, for: user, on: db)
            guard game.status == .invited, seat == .two else {
                throw AppError.invalidState("There's no challenge here for you to decline.")
            }
            let challengerID = game.userID(at: .one)
            try await game.delete(on: db)

            await notifier.removed(gameID, reason: .declined, notifying: [challengerID, user.id])
            notifier.push(.challengeDeclined(by: user.username, gameID: gameID), to: challengerID)
        }
    }

    /// Withdraws a game that hasn't started: a matchmaking request or an unanswered challenge.
    func cancel(_ gameID: UUID, by user: User, on db: any Database) async throws {
        try await writeLock.withLock {
            let (game, seat) = try await load(gameID, for: user, on: db)
            guard game.status == .matchmaking || game.status == .invited, seat == .one else {
                throw AppError.invalidState("Only a game that hasn't started can be cancelled.")
            }
            let participants = [game.userID(at: .one), game.userID(at: .two)]
            try await game.delete(on: db)
            await notifier.removed(gameID, reason: .cancelled, notifying: participants)
        }
    }

    // MARK: Playing

    func fire(at target: Coordinate, in gameID: UUID, by user: User, on db: any Database) async throws -> FireResponse {
        try await writeLock.withLock {
            let (game, seat) = try await load(gameID, for: user, on: db)
            guard game.status == .active, var battle = try game.battle() else {
                throw game.status == .finished
                    ? AppError(BattleError.gameOver)
                    : AppError.invalidState("The battle hasn't started yet.")
            }

            let move: Move
            do {
                move = try battle.fire(seat, at: target)
            } catch let error as BattleError {
                throw AppError(error)
            }
            game.apply(battle)
            try await commit(game, on: db)

            await notifier.broadcast(game)
            let opponentID = game.userID(at: seat.opponent)
            if battle.isOver {
                notifier.push(.defeat(by: user.username, gameID: gameID), to: opponentID)
            } else {
                notifier.push(.incoming(move, from: user.username, gameID: gameID), to: opponentID)
            }
            return FireResponse(move: move, game: try notifier.presenter.detail(of: game, for: seat))
        }
    }

    func resign(_ gameID: UUID, by user: User, on db: any Database) async throws -> GameDetail {
        try await writeLock.withLock {
            let (game, seat) = try await load(gameID, for: user, on: db)
            guard game.status == .active, var battle = try game.battle() else {
                throw AppError.invalidState("You can only resign a battle in progress.")
            }
            try battle.resign(seat)
            game.apply(battle)
            try await commit(game, on: db)

            await notifier.broadcast(game)
            notifier.push(.opponentResigned(user.username, gameID: gameID), to: game.userID(at: seat.opponent))
            return try notifier.presenter.detail(of: game, for: seat)
        }
    }

    /// Wins a battle whose opponent has let their move time run out.
    func claimVictory(_ gameID: UUID, by user: User, on db: any Database) async throws -> GameDetail {
        try await writeLock.withLock {
            let (game, seat) = try await load(gameID, for: user, on: db)
            guard game.status == .active, var battle = try game.battle() else {
                throw AppError.invalidState("Only a battle in progress can be won on time.")
            }
            guard battle.turn == seat.opponent else {
                throw AppError.invalidState("It's your move, so there's nothing to claim.")
            }
            guard Date() >= game.lastActivity.addingTimeInterval(settings.turnTimeLimit) else {
                throw AppError.opponentStillHasTime
            }
            try battle.forfeit(seat.opponent, reason: .timeout)
            game.apply(battle)
            try await commit(game, on: db)

            await notifier.broadcast(game)
            notifier.push(.outOfTime(claimedBy: user.username, gameID: gameID), to: game.userID(at: seat.opponent))
            return try notifier.presenter.detail(of: game, for: seat)
        }
    }

    // MARK: Accounts

    /// Removes a player: games that haven't started are withdrawn, battles in progress are resigned
    /// (their opponents win), and finished games stay in the opponents' history as "former player".
    func deleteAccount(of user: User, on db: any Database) async throws {
        let userID = try user.requireID()
        try await writeLock.withLock {
            let games = try await participating(userID, on: db).all()

            let (removed, resigned) = try await db.transaction { tx in
                var removed: [(gameID: UUID, notify: [UUID?])] = []
                var resigned: [GameRecord] = []
                for game in games {
                    guard let seat = game.seat(of: userID) else { continue }
                    switch game.status {
                    case .matchmaking, .invited:
                        removed.append((try game.requireID(), [game.userID(at: seat.opponent)]))
                        try await game.delete(on: tx)
                    case .active:
                        guard var battle = try game.battle() else { continue }
                        try battle.resign(seat)
                        game.apply(battle)
                        try await recordResult(of: game, on: tx)
                        try await game.save(on: tx)
                        resigned.append(game)
                    case .finished:
                        break
                    }
                }
                // Tokens and devices go with the user (ON DELETE CASCADE); seats in finished games
                // become empty (ON DELETE SET NULL). Delete explicitly too, for databases without FKs.
                try await UserToken.query(on: tx).filter(\.$user.$id == userID).delete()
                try await Device.query(on: tx).filter(\.$user.$id == userID).delete()
                try await user.delete(on: tx)
                return (removed, resigned)
            }

            for (gameID, participants) in removed {
                await notifier.removed(gameID, reason: .cancelled, notifying: participants)
            }
            for game in resigned {
                guard let seat = game.seat(of: userID) else { continue }
                // The departing player's seat is now empty in the opponent's view.
                if seat == .one { game.$playerOne.value = .some(nil) } else { game.$playerTwo.value = .some(nil) }
                await notifier.broadcast(game)
                notifier.push(.opponentLeft(gameID: try game.requireID()), to: game.userID(at: seat.opponent))
            }
            await notifier.hub.disconnectAll(userID: userID)
        }
    }

    // MARK: Helpers

    private func participating(_ userID: UUID, on db: any Database) -> QueryBuilder<GameRecord> {
        GameRecord.query(on: db)
            .group(.or) { group in
                group.filter(\.$playerOne.$id == userID).filter(\.$playerTwo.$id == userID)
            }
            .with(\.$playerOne)
            .with(\.$playerTwo)
    }

    /// Loads a game the user plays in. Games they aren't part of are reported as not found.
    private func load(_ gameID: UUID, for user: User, on db: any Database) async throws -> (GameRecord, Player) {
        guard let game = try await GameRecord.query(on: db)
            .filter(\.$id == gameID)
            .with(\.$playerOne)
            .with(\.$playerTwo)
            .first(),
            let seat = game.seat(of: try user.requireID())
        else { throw AppError.gameNotFound }
        return (game, seat)
    }

    private func validate(_ fleet: [ShipPlacement], for mode: GameMode) throws {
        do {
            try mode.rules.validate(fleet)
        } catch let error as FleetError {
            throw AppError(error)
        }
    }

    /// Games the player started or is actively playing. Unanswered challenges *to* the player don't
    /// count, so nobody can lock someone else out by flooding them with challenges.
    private func enforceOpenGameLimit(for user: User, on db: any Database) async throws {
        let userID = try user.requireID()
        let open = try await GameRecord.query(on: db)
            .filter(\.$statusRaw != GameStatus.finished.rawValue)
            .group(.or) { group in
                group.filter(\.$playerOne.$id == userID)
                    .group(.and) { mine in
                        mine.filter(\.$playerTwo.$id == userID).filter(\.$statusRaw == GameStatus.active.rawValue)
                    }
            }
            .count()
        guard open < settings.maxOpenGamesPerPlayer else {
            throw AppError.tooManyGames(limit: settings.maxOpenGamesPerPlayer)
        }
    }

    /// Saves a move or resignation, and the players' new ratings if it ended the game, atomically.
    private func commit(_ game: GameRecord, on db: any Database) async throws {
        try await db.transaction { tx in
            if game.status == .finished {
                try await recordResult(of: game, on: tx)
            }
            try await game.save(on: tx)
        }
    }

    private func recordResult(of game: GameRecord, on db: any Database) async throws {
        guard let outcome = game.outcome,
              let winnerID = game.userID(at: outcome.winner),
              let loserID = game.userID(at: outcome.loser),
              let winner = try await User.find(winnerID, on: db),
              let loser = try await User.find(loserID, on: db)
        else { return }

        let ratings = Elo.ratings(winner: winner.rating, loser: loser.rating)
        winner.rating = ratings.winner
        winner.wins += 1
        loser.rating = ratings.loser
        loser.losses += 1
        try await winner.save(on: db)
        try await loser.save(on: db)

        // Keep the loaded players current so the views sent out show the new ratings.
        if outcome.winner == .one {
            game.$playerOne.value = winner
            game.$playerTwo.value = loser
        } else {
            game.$playerOne.value = loser
            game.$playerTwo.value = winner
        }
    }
}
