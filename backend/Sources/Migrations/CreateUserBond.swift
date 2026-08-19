import Fluent

struct CreateUserBond: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_bonds")
            .field("id", .int, .identifier(auto: true))
            // 照護者 ID，指向 users 表
            .field("caregiver_id", .int, .required, .references("users", "id", onDelete: .cascade))
            // 被照護者 (病患) ID，指向 users 表
            .field("patient_id", .int, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            // 聯合唯一約束，防止 A 與 B 重複建立綁定關係
            .unique(on: "caregiver_id", "patient_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_bonds").delete()
    }
}
