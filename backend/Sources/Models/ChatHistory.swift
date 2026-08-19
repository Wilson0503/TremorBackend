import Fluent
import Vapor

final class ChatHistory: Model, Content, @unchecked Sendable {
    static let schema = "chat_history"
    
    @ID(key: .id)
    var id: UUID?
    
    // 辨識是哪位使用者的對話 (若目前還沒有會員系統，可以先用 UUID 或字串代替)
    @Field(key: "user_id")
    var userID: String
    
    @Field(key: "role")
    var role: String
    
    @Field(key: "content")
    var content: String
    
    // ✅ 正確的寫法
    @OptionalField(key: "embedding")
    var embedding: [Float]?
    
    // 建立時間，用來排序抓取最新對話
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    init() { }
    
    init(id: UUID? = nil, userID: String, role: String, content: String) {
        self.id = id
        self.userID = userID
        self.role = role
        self.content = content
    }
}
