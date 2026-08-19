import Fluent

struct CreateMedicationPlan: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("medication_plans")
            .field("id", .int, .identifier(auto: true))
            .field("user_id", .int, .required, .references("users", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("dose", .string, .required)
            .field("med_type", .string, .required)
            .field("default_patch_region", .string)
            .field("time_slots_raw", .string, .required)
            .field("start_date", .datetime, .required) // 👇 新增這個欄位
            .field("repeat_frequency", .string, .required)
            .field("custom_interval", .int, .required)
            .field("custom_unit", .string, .required)
            .field("weekdays_raw", .string, .required)
            .field("month_days_raw", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("medication_plans").delete()
    }
}
