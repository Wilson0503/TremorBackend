import Fluent

struct CreateMedicationRecord: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("medication_records")
            .field("id", .int, .identifier(auto: true))
            .field("user_id", .int, .required, .references("users", "id", onDelete: .cascade))
            .field("date", .datetime, .required) // 儲存用藥日期
            .field("name", .string, .required) // 藥品名稱
            .field("dose", .string, .required) // 劑量
            .field("created_at", .datetime)    // 資料建立時間（方便追蹤）
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("medication_records").delete()
    }
}
