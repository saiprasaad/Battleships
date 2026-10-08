import Foundation

/// Why a player is being reported to the people running the server.
public enum ReportReason: String, Codable, Sendable, CaseIterable, Hashable {
    case offensiveUsername
    case harassment
    case cheating
    case other

    public var displayName: String {
        switch self {
        case .offensiveUsername: "Offensive username"
        case .harassment: "Harassment"
        case .cheating: "Cheating"
        case .other: "Something else"
        }
    }
}

/// `POST /v1/players/:id/report`.
public struct ReportPlayerRequest: Codable, Sendable, Hashable {
    public var reason: ReportReason
    /// The game the report is about, if any.
    public var gameID: UUID?

    public init(reason: ReportReason, gameID: UUID? = nil) {
        self.reason = reason
        self.gameID = gameID
    }
}
