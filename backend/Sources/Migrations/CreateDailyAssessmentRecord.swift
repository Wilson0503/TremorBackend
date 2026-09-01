import Fluent

struct CreateDailyAssessmentRecord: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("daily_assessment_records")
            .field("id", .int, .identifier(auto: true))
            .field("user_id", .int, .required, .references("users", "id", onDelete: .cascade))
            .field("date", .datetime, .required)
            .field("total_score", .int, .required)
            .field("mood_score", .int, .required)
            .field("adl_score", .int, .required)
            .field("motor_score", .int, .required)
            .field("details_json", .string) // 儲存 25 題詳細作答選項
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("daily_assessment_records").delete()
    }
}
