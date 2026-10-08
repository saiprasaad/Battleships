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
