import Fluent

struct CreateSymptomRecord: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("symptom_records")
            .field("id", .int, .identifier(auto: true))
            .field("user_id", .int, .required, .references("users", "id", onDelete: .cascade))
            .field("date", .datetime, .required)
            .field("symptom_note", .string, .required)
            .field("media_data_list", .array(of: .data), .required) // 儲存 Data 陣列
            .field("is_video", .bool, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("symptom_records").delete()
    }
}
