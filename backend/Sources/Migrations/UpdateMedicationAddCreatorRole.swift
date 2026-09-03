import Fluent

struct UpdateMedicationAddCreatorRole: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // 1. 為用藥紀錄表新增建立者身分
        try await database.schema("medication_records")
            .field("creator_role", .int, .required, .sql(.default(0)))
            .update()

        // 2. 為用藥排程表新增建立者身分
        try await database.schema("medication_plans")
            .field("creator_role", .int, .required, .sql(.default(0)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("medication_records")
            .deleteField("creator_role")
            .update()

        try await database.schema("medication_plans")
            .deleteField("creator_role")
            .update()
    }
}
