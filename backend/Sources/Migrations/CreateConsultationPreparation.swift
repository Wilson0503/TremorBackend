import Fluent

struct CreateConsultationPreparation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("consultation_preparations")
            .field("id", .int, .identifier(auto: true))
            .field("user_id", .int, .required, .references("users", "id", onDelete: .cascade))
            .field("content", .string, .required)
            .field("updated_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "user_id") // 🔥 確保每位病患僅有一筆當前生效的看診準備提示
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("consultation_preparations").delete()
    }
}
