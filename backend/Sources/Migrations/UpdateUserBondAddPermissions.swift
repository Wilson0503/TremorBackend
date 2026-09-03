import Fluent

struct UpdateUserBondAddPermissions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_bonds")
            .field("can_manage_med_plan", .bool, .required, .sql(.default(false)))
            .field("can_add_med_record", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_bonds")
            .deleteField("can_manage_med_plan")
            .deleteField("can_add_med_record")
            .update()
    }
}
