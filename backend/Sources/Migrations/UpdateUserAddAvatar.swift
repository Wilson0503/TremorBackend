import Fluent

struct UpdateUserAddAvatar: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("avatar_data", .data) // 二進位儲存，可為 null
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("avatar_data")
            .update()
    }
}
