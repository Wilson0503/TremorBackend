import Fluent

struct CreateChatHistory: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("chat_history")
            .id()
            .field("user_id", .string, .required)
            .field("role", .string, .required)
            .field("content", .string, .required)
            .field("embedding", .custom("vector(1536)"))
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("chat_history").delete()
    }
}
