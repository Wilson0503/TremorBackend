import Fluent

struct UpdateDailyRecordAddCaregiverOnly: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // 在現有的 daily_records 表格中加入 is_caregiver_only 欄位，預設為 false
        try await database.schema("daily_records")
            .field("is_caregiver_only", .bool, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("daily_records")
            .deleteField("is_caregiver_only")
            .update()
    }
}
