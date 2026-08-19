import Fluent
import FluentSQL

struct CreateKnowledgeBase: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // 1. 確保 PostgreSQL 資料庫中已經啟用了 vector 擴充功能
        if let sql = database as? any SQLDatabase { // 🔥 加上了 any
            try await sql.raw("CREATE EXTENSION IF NOT EXISTS vector").run()
        }
        
        // 2. 建立資料表
        try await database.schema(KnowledgeBase.schema)
            .id()
            .field("category", .string, .required)
            .field("content", .string, .required)
            .create()
        
        // 3. 使用原生 SQL 加上 1536 維度的 vector 欄位
        if let sql = database as? any SQLDatabase { // 🔥 加上了 any
            // 🔥 把 raw: 改成了 unsafeRaw: 消除警告
            try await sql.raw("ALTER TABLE \(unsafeRaw: KnowledgeBase.schema) ADD COLUMN embedding vector(1536)").run()
            
            // （選擇性）建立 HNSW 索引以加速向量搜尋
            try await sql.raw("CREATE INDEX ON \(unsafeRaw: KnowledgeBase.schema) USING hnsw (embedding vector_cosine_ops)").run()
        }
    }
    
    func revert(on database: any Database) async throws {
        try await database.schema(KnowledgeBase.schema).delete()
    }
}
