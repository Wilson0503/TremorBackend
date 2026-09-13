import Fluent

struct UpdateUserAddPasswordReset: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("reset_code", .string)
            .field("reset_code_expires_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("reset_code")
            .deleteField("reset_code_expires_at")
            .update()
    }
}
