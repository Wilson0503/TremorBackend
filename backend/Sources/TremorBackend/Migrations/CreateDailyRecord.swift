import Fluent

struct CreateDailyRecord: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("daily_records")
            .field("id", .string, .identifier(auto: false)) // 使用前端的 UUID 字串作為主鍵
            .field("user_id", .int, .required, .references("users", "id", onDelete: .cascade))
            .field("content", .string, .required)
            .field("date", .datetime, .required)
            .field("color_hex", .string, .required)
            .field("sender", .string, .required)
            .field("mood_name", .string)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("daily_records").delete()
    }
}
