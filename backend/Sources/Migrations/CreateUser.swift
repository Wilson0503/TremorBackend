import Fluent

struct CreateUser: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("id", .int, .identifier(auto: true))
            .field("email", .string, .required)
            .field("password_hash", .string, .required)
            .field("name", .string)
            .field("birth", .date)
            .field("gender", .int)
            .field("disease_stage", .string)
            .field("pairing_code", .string)
            .field("pairing_code_expires_at", .datetime)
            .field("role", .int, .required)
            .field("active_session_id", .string)
            .unique(on: "email")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users").delete()
    }
}
