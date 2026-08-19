import Fluent

struct CreateMedicationRecord: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("medication_records")
            .field("id", .int, .identifier(auto: true))
            .field("user_id", .int, .required, .references("users", "id", onDelete: .cascade))
            .field("date", .datetime, .required)
            .field("name", .string, .required)
            .field("dose", .string, .required)
            .field("med_type", .string, .required)
            .field("patch_region", .string)
            .field("skin_condition", .string)
            .field("skin_image_data_list", .array(of: .data), .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("medication_records").delete()
    }
}
