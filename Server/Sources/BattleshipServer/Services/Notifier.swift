import BattleshipAPI
import BattleshipCore
import Fluent
import Vapor

/// Tells players about changes to their games: instantly over WebSocket, and by push notification
/// for the things worth interrupting someone for.
struct Notifier: Sendable {
    let presenter: GamePresenter
    let hub: RealtimeHub
    let push: any PushService
    let writeLock: AsyncLock
    let database: @Sendable () -> any Database
    let logger: Logger

    /// Sends each player in `game` their own up-to-date view of it. Expects both players to be loaded.
    func broadcast(_ game: GameRecord) async {
        for seat in Player.allCases {
            guard let userID = game.userID(at: seat) else { continue }
            do {
                let detail = try presenter.detail(of: game, for: seat)
                await hub.send(.gameUpdated(detail), to: userID)
            } catch {
                logger.error("Could not present game \(game.id?.uuidString ?? "?"): \(error)")
            }
        }
    }

    func removed(_ gameID: UUID, reason: GameRemovalReason, notifying userIDs: [UUID?]) async {
        for userID in Set(userIDs.compactMap { $0 }) {
            await hub.send(.gameRemoved(gameID: gameID, reason: reason), to: userID)
        }
    }

    /// Pushes `message` to every device `userID` is signed in on. Runs in the background, outside the
    /// write lock, so a slow APNs round trip never holds up a move; tokens Apple rejects are forgotten.
    func push(_ message: PushMessage, to userID: UUID?) {
        guard let userID else { return }
        let push = push, writeLock = writeLock, database = database, logger = logger
        Task {
            do {
                let devices = try await Self.signedInDevices(of: userID, on: database())
                guard !devices.isEmpty else { return }
                let targets = devices.map { PushTarget(token: $0.token, environment: $0.pushEnvironment) }
                let invalid = await push.send(message, to: targets)
                guard !invalid.isEmpty else { return }
                try await writeLock.withLock {
                    try await Device.query(on: database()).filter(\.$token ~~ invalid).delete()
                }
            } catch {
                logger.warning("Push notification failed: \(error)")
            }
        }
    }

    /// The player's devices whose session is still live. A device registered before sessions were
    /// recorded has none, and counts until the app registers it again.
    static func signedInDevices(of userID: UUID, on db: any Database) async throws -> [Device] {
        let devices = try await Device.query(on: db).filter(\.$user.$id == userID).all()
        let sessionIDs = devices.compactMap { $0.$session.id }
        let live: Set<UUID> = sessionIDs.isEmpty ? [] : Set(try await UserToken.query(on: db)
            .filter(\.$id ~~ sessionIDs)
            .filter(\.$expiresAt > Date())
            .all(\.$id))
        return devices.filter { device in device.$session.id.map(live.contains) ?? true }
    }
}

extension PushMessage {
    static func challenge(from challenger: String, mode: GameMode, gameID: UUID) -> PushMessage {
        PushMessage(title: "New challenge", body: "\(challenger) challenged you to a \(mode.displayName) battle.", gameID: gameID)
    }

    static func challengeAccepted(by opponent: String, gameID: UUID) -> PushMessage {
        PushMessage(title: "Challenge accepted", body: "\(opponent) is ready for battle. You fire first!", gameID: gameID)
    }

    static func challengeDeclined(by opponent: String, gameID: UUID) -> PushMessage {
        PushMessage(title: "Challenge declined", body: "\(opponent) declined your challenge.", gameID: gameID)
    }

    static func opponentFound(_ opponent: String, gameID: UUID) -> PushMessage {
        PushMessage(title: "Opponent found", body: "You're up against \(opponent). You fire first!", gameID: gameID)
    }

    static func incoming(_ move: Move, from opponent: String, gameID: UUID) -> PushMessage {
        let body = switch move.result {
        case .miss: "\(opponent) fired at \(move.target) and missed."
        case .hit: "\(opponent) hit your ship at \(move.target)!"
        case let .sunk(kind): "\(opponent) sank your \(kind.displayName)!"
        }
        return PushMessage(title: "Your turn", body: body, gameID: gameID)
    }

    static func defeat(by opponent: String, gameID: UUID) -> PushMessage {
        PushMessage(title: "Defeat", body: "\(opponent) sank your last ship.", gameID: gameID)
    }

    static func opponentResigned(_ opponent: String, gameID: UUID) -> PushMessage {
        PushMessage(title: "Victory!", body: "\(opponent) resigned. You win!", gameID: gameID)
    }

    static func outOfTime(claimedBy opponent: String, gameID: UUID) -> PushMessage {
        PushMessage(title: "Out of time", body: "You didn't move in time, so \(opponent) claimed the win.", gameID: gameID)
    }

    static func opponentLeft(gameID: UUID) -> PushMessage {
        PushMessage(title: "Victory!", body: "Your opponent left Battleships. You win!", gameID: gameID)
    }
}
