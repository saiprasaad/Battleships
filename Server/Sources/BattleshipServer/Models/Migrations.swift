import Fluent
import FluentSQL

struct CreateUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .id()
            .field("username", .string, .required)
            .field("username_key", .string, .required)
            .field("password_hash", .string, .required)
            .field("rating", .int, .required)
            .field("wins", .int, .required)
            .field("losses", .int, .required)
            .field("created_at", .datetime)
            .unique(on: "username_key")
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.create(index: "users_rating_idx").on(User.schema).column("rating").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).delete()
    }
}

struct CreateUserTokens: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserToken.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserToken.schema).delete()
    }
}

struct CreateGames: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(GameRecord.schema)
            .id()
            .field("mode", .string, .required)
            .field("status", .string, .required)
            .field("player_one_id", .uuid, .references(User.schema, .id, onDelete: .setNull))
            .field("player_two_id", .uuid, .references(User.schema, .id, onDelete: .setNull))
            .field("fleet_one", .json, .required)
            .field("fleet_two", .json)
            .field("moves", .json, .required)
            .field("turn", .int)
            .field("winner", .int)
            .field("end_reason", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.create(index: "games_player_one_idx").on(GameRecord.schema).column("player_one_id").run()
            try await sql.create(index: "games_player_two_idx").on(GameRecord.schema).column("player_two_id").run()
            try await sql.create(index: "games_queue_idx").on(GameRecord.schema)
                .column("status").column("mode").column("created_at").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(GameRecord.schema).delete()
    }
}

struct CreateDevices: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Device.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("token", .string, .required)
            .field("environment", .string, .required)
            .field("updated_at", .datetime)
            .unique(on: "token")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Device.schema).delete()
    }
}

struct CreateBlocks: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Block.schema)
            .id()
            .field("blocker_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("blocked_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "blocker_id", "blocked_id")
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.create(index: "blocks_blocked_idx").on(Block.schema).column("blocked_id").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Block.schema).delete()
    }
}

struct CreateReports: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Report.schema)
            .id()
            .field("reporter_id", .uuid, .references(User.schema, .id, onDelete: .setNull))
            .field("reported_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("reason", .string, .required)
            .field("game_id", .uuid)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Report.schema).delete()
    }
}

/// Ties each push device to the session that registered it (see ``Device/session``). Existing rows
/// keep a `NULL` session and go on receiving notifications until the app registers them again.
struct AddDeviceSessions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Device.schema)
            .field("session_id", .uuid, .references(UserToken.schema, .id, onDelete: .cascade))
            .update()
        if let sql = database as? any SQLDatabase {
            try await sql.create(index: "devices_session_idx").on(Device.schema).column("session_id").run()
        }
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.drop(index: "devices_session_idx").run()
        }
        try await database.schema(Device.schema).deleteField("session_id").update()
    }
}

/// Indexes for lookups on busy paths: sessions and devices by player (every push, sign-out and
/// account deletion), expired sessions (purged at sign-in), and reports by player.
struct AddLookupIndexes: AsyncMigration {
    private static let indexes: [(name: String, table: String, column: String)] = [
        ("user_tokens_user_idx", UserToken.schema, "user_id"),
        ("user_tokens_expires_idx", UserToken.schema, "expires_at"),
        ("devices_user_idx", Device.schema, "user_id"),
        ("reports_reported_idx", Report.schema, "reported_id"),
        ("reports_reporter_idx", Report.schema, "reporter_id"),
    ]

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        for index in Self.indexes {
            try await sql.create(index: index.name).on(index.table).column(index.column).run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        for index in Self.indexes {
            try await sql.drop(index: index.name).run()
        }
    }
}

struct CreateExternalIdentities: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ExternalIdentity.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("provider", .string, .required)
            .field("subject", .string, .required)
            .field("apple_refresh_token", .string)
            .field("created_at", .datetime)
            .unique(on: "provider", "subject")
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.create(index: "external_identities_user_idx").on(ExternalIdentity.schema).column("user_id").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ExternalIdentity.schema).delete()
    }
}

struct CreateSignupTickets: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(SignupTicket.schema)
            .id()
            .field("ticket_hash", .string, .required)
            .field("provider", .string, .required)
            .field("subject", .string, .required)
            .field("apple_refresh_token", .string)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .unique(on: "ticket_hash")
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.create(index: "signup_tickets_expires_idx").on(SignupTicket.schema).column("expires_at").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(SignupTicket.schema).delete()
    }
}
