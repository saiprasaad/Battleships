import FluentPostgresDriver

/// A value kept in a single JSON column.
///
/// Fluent hands a Swift array to Postgres as a Postgres array (`jsonb[]`), which a `jsonb` column
/// rejects, so on Postgres no game could ever be saved. Wrapped like this, the value goes to Postgres
/// as one JSON document. SQLite stores exactly the JSON text it stored for the bare array, so
/// existing SQLite databases read and write the same as before and need no migration.
struct JSONColumn<Value: Codable & Sendable>: Codable, Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(Value.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// PostgresNIO's default implementations for `Codable` types read and write `jsonb`.
extension JSONColumn: PostgresEncodable, PostgresDecodable {}
