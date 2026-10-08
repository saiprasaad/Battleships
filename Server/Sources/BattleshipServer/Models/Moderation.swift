import BattleshipAPI
import Fluent
import Vapor

/// One player blocking another. Blocked players can't challenge their blocker, and matchmaking
/// never pairs the two.
final class Block: Model, @unchecked Sendable {
    static let schema = "blocks"

    @ID(key: .id) var id: UUID?
    @Parent(key: "blocker_id") var blocker: User
    @Parent(key: "blocked_id") var blocked: User
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(blockerID: UUID, blockedID: UUID) {
        self.$blocker.id = blockerID
        self.$blocked.id = blockedID
    }

    /// Everyone `userID` has blocked or been blocked by.
    static func counterparts(of userID: UUID, on db: any Database) async throws -> Set<UUID> {
        let blocks = try await Block.query(on: db)
            .group(.or) { $0.filter(\.$blocker.$id == userID).filter(\.$blocked.$id == userID) }
            .all()
        return Set(blocks.map { $0.$blocker.id == userID ? $0.$blocked.id : $0.$blocker.id })
    }
}

/// A player reporting another, for the people running the server to review.
final class Report: Model, @unchecked Sendable {
    static let schema = "reports"

    @ID(key: .id) var id: UUID?
    @OptionalParent(key: "reporter_id") var reporter: User?
    @Parent(key: "reported_id") var reported: User
    @Field(key: "reason") var reason: String
    @OptionalField(key: "game_id") var gameID: UUID?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(reporterID: UUID, reportedID: UUID, reason: ReportReason, gameID: UUID?) {
        self.$reporter.id = reporterID
        self.$reported.id = reportedID
        self.reason = reason.rawValue
        self.gameID = gameID
    }
}
