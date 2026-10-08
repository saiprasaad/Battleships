import Foundation

public enum GameRemovalReason: String, Codable, Sendable, Hashable {
    /// The challenged player turned the challenge down.
    case declined
    /// The player who created the game withdrew it before it started.
    case cancelled
}

/// Messages pushed to the app over the realtime WebSocket (`GET /v1/events`).
public enum ServerEvent: Sendable, Hashable {
    /// Sent once when the connection is ready.
    case hello
    /// A game you are part of changed: an opponent joined, accepted, fired, resigned…
    case gameUpdated(GameDetail)
    /// A game you were part of no longer exists.
    case gameRemoved(gameID: UUID, reason: GameRemovalReason)
}

extension ServerEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, game, gameID, reason
    }

    private enum Kind: String, Codable {
        case hello, gameUpdated, gameRemoved
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .hello:
            self = .hello
        case .gameUpdated:
            self = .gameUpdated(try container.decode(GameDetail.self, forKey: .game))
        case .gameRemoved:
            self = .gameRemoved(
                gameID: try container.decode(UUID.self, forKey: .gameID),
                reason: try container.decode(GameRemovalReason.self, forKey: .reason)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello:
            try container.encode(Kind.hello, forKey: .type)
        case let .gameUpdated(game):
            try container.encode(Kind.gameUpdated, forKey: .type)
            try container.encode(game, forKey: .game)
        case let .gameRemoved(gameID, reason):
            try container.encode(Kind.gameRemoved, forKey: .type)
            try container.encode(gameID, forKey: .gameID)
            try container.encode(reason, forKey: .reason)
        }
    }
}
