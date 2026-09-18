import Fluent
import FluentSQL

struct CreateTremorTrendPoints: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("tremor_trend_points")
            .field("id", .uuid, .identifier(auto: false))
            .field("user_id", .int, .required, .references("users", "id", onDelete: .cascade))
            .field("session_id", .string, .required)
            .field("recorded_at", .datetime, .required)
            .field("rms_value", .double, .required)
            .field("dominant_frequency_hz", .double)
            .field("motor_on_fraction", .double, .required)
            .field("data_valid", .bool, .required)
            .field("frequency_reliable", .bool, .required)
            .field("created_at", .datetime)
            .create()

        // 🔥 關鍵補強：建立 (user_id, recorded_at) 複合索引，避免全表掃描
        if let sql = database as? any SQLDatabase {
            try await sql.raw("""
                CREATE INDEX idx_trend_points_user_recorded 
                ON tremor_trend_points (user_id, recorded_at);
            """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("tremor_trend_points").delete()
    }
}
