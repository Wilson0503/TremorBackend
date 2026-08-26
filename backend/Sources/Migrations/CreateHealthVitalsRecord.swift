import Fluent

struct CreateHealthVitalsRecord: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("health_vitals_records")
            .field("id", .int, .identifier(auto: true))
            .field("user_id", .int, .required, .references("users", "id", onDelete: .cascade))
            .field("date", .datetime, .required)
            .field("systolic_bp", .string)
            .field("diastolic_bp", .string)
            .field("blood_sugar", .string)
            .field("body_temp", .string)
            .field("body_weight", .string)
            .field("sleep_hours", .string)
            .field("food_amount", .string)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("health_vitals_records").delete()
    }
}
