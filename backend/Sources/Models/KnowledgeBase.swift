import Fluent
import Vapor

final class KnowledgeBase: Model, Content, @unchecked Sendable {
    static let schema = "knowledge_base"
    
    @ID(key: .id)
    var id: UUID?
    
    // 知識的分類（例如："hardware", "medical", "app_guide"）
    @Field(key: "category")
    var category: String
    
    // 知識的實際文字內容（例如："若手套藍牙連線失敗，請長按電源鍵 5 秒..."）
    @Field(key: "content")
    var content: String
    
    // 🔥 儲存文字轉化後的向量矩陣
    // 在 Fluent 中，向量是以 [Float] (浮點數陣列) 來表示
    @Field(key: "embedding")
    var embedding: [Float]
    
    init() { }
    
    init(id: UUID? = nil, category: String, content: String, embedding: [Float]) {
        self.id = id
        self.category = category
        self.content = content
        self.embedding = embedding
    }
}
