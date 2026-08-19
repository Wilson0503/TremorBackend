import Fluent

struct CreateNewTremorTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // 1. 建立 Raw 原始數據表
        // 在建立 raw_tremor_data 的區塊中
        try await database.schema("raw_tremor_data")
            .field("id", .int, .identifier(auto: true))
            .field("user_id", .int, .required, .references("users", "id", onDelete: .cascade))
            .field("session_id", .string, .required)
            .field("sequence", .int, .required)          // 👈 修改為 .int
            .field("sample_tick_ms", .int, .required)    // 👈 修改為 .int
            .field("gyro_x_dps", .double, .required)
            .field("gyro_y_dps", .double, .required)
            .field("gyro_z_dps", .double, .required)
            .field("sensor_valid", .int, .required)      // 👈 修改為 .int
            .field("motor_enabled", .int, .required)     // 👈 修改為 .int
            .field("created_at", .datetime)
            .create()
        
        // 2. 建立演算法分析結果表
        try await database.schema("tremor_analysis_records")
            .field("id", .uuid, .identifier(auto: false))
            .field("user_id", .int, .required, .references("users", "id", onDelete: .cascade))
            .field("session_id", .string, .required)
            .field("recorded_at", .datetime, .required)
            .field("dominant_frequency_hz", .double)
            .field("tremor_strength_rms_dps", .double)
            .field("motor_on_fraction", .double, .required)
            .field("data_valid", .bool, .required)
            .field("frequency_reliable", .bool, .required)
            .field("activity_tag", .string, .required)
            .field("note", .string)
            .create()
    }
    
    func revert(on database: any Database) async throws {
        try await database.schema("raw_tremor_data").delete()
        try await database.schema("tremor_analysis_records").delete()
    }
}
