import Fluent

struct CreateTremorData: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("tremor_data")
            // 修正這行，改為 Int 且自動遞增
            .field("id", .int, .identifier(auto: true))
            // 修改這一行，加入 references 指向 users 表的 id
            .field("user_id", .int, .required, .references("users", "id", onDelete: .cascade))
            .field("timestamp", .datetime)
            .field("acc_x", .double, .required)
            .field("acc_y", .double, .required)
            .field("acc_z", .double, .required)
            .field("gyro_x", .double, .required)
            .field("gyro_y", .double, .required)
            .field("gyro_z", .double, .required)
            .field("tremor_frequency", .double)
            .field("amplitude", .double)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("tremor_data").delete()
    }
}
