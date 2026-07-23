import Vapor
import Foundation

struct AIController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let ai = routes.grouped("api", "ai")
        ai.post("chat", use: handleChat)
    }
    
    @Sendable
    func handleChat(req: Request) async throws -> ChatResponseDTO {
        // 1. 確保身分
        let _ = try req.auth.require(UserPayload.self)
        
        // 2. 解析前端問題
        struct ChatRequestDTO: Content {
            let message: String
        }
        let userRequest = try req.content.decode(ChatRequestDTO.self)
        
        // 3. 取得並清理金鑰
        guard let rawApiKey = Environment.get("GEMINI_API_KEY") else {
            throw Abort(.internalServerError, reason: "後端未配置 AI 金鑰")
        }
        let apiKey = rawApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 💡 診斷日誌：確認讀到的是正確的個人金鑰
        req.logger.info("【金鑰驗證】目前正在使用金鑰開頭：\(apiKey.prefix(12))")
        
        // 4.配置超低延遲的 3.1 Flash-Lite 模型
        let modelName = "gemini-3.1-flash-lite"
        let geminiURL = "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent"
        
        // 🔥 更新：在提示詞中強制限制字數與嚴格限制回答範圍
        let systemPrompt = """
                【系統最高指引：你是專屬的「帕金森氏症防手抖手套與照護 App 助手（小安）」。】
                
                回答範圍嚴格限制在以下三點：
                1. 帕金森氏症、手抖相關的衛教知識與心理陪伴。
                2. 防手抖穿戴手套的硬體操作與疑難排解。
                3. 本照護 App 的功能教學（如便利貼、用藥紀錄、帳號綁定）。
                
                 拒絕政策：若使用者的問題完全無關上述三點（例如：食譜、天氣、政治、歷史、寫程式、一般閒聊等），你「必須」溫和但堅定地拒絕回答，並主動提醒使用者你只能協助帕金森氏症與手套相關問題。絕對不能順著使用者的無關話題聊下去。
                
                要求：語氣具同理心，涉及專業醫療診斷時務必提醒患者就醫。為了體貼患者閱讀，請務必精簡回答，字數嚴格限制在 150-200 字以內，分段清晰。
                """
        
        let combinedMessage = "\(systemPrompt)\n\n使用者提問：\(userRequest.message)"
        
        let requestBody = GeminiRequest(
            contents: [
                .init(role: "user", parts: [.init(text: combinedMessage)])
            ]
        )
        
        // 5. 建立 Headers
        var googleHeaders = HTTPHeaders()
        googleHeaders.add(name: "Content-Type", value: "application/json")
        googleHeaders.add(name: "x-goog-api-key", value: apiKey)
        
        // 發送標準請求
        let clientResponse = try await req.client.post(URI(string: geminiURL), headers: googleHeaders) {
            try $0.content.encode(requestBody, as: .json)
        }
        
        // 6. 解析回覆
        guard clientResponse.status == .ok else {
            let bytesLength = clientResponse.body?.readableBytes ?? 0
            let errorBody = clientResponse.body?.getString(at: 0, length: bytesLength) ?? "無錯誤內文"
            
            req.logger.error("Gemini API 呼叫失敗，狀態碼：\(clientResponse.status)，詳細原因：\(errorBody)")
            
            throw Abort(.badGateway, reason: "AI 陪伴助手暫時忙碌中，請稍後再試")
        }
        
        let geminiResponse = try clientResponse.content.decode(GeminiResponse.self)
        
        guard let aiReply = geminiResponse.candidates?.first?.content.parts.first?.text else {
            throw Abort(.internalServerError, reason: "生成回應失敗，請重新嘗試")
        }
        
        return ChatResponseDTO(reply: aiReply)
    }
}

// =-=-=-=-=-= DTO 模型 =-=-=-=-=-=
struct GeminiRequest: Content {
    struct ContentObj: Codable {
        struct Part: Codable {
            let text: String
        }
        let role: String
        let parts: [Part]
    }
    let contents: [ContentObj]
}

struct GeminiResponse: Codable {
    struct Candidate: Codable {
        struct ContentObj: Codable {
            struct Part: Codable {
                let text: String
            }
            let parts: [Part]
        }
        let content: ContentObj
    }
    let candidates: [Candidate]?
}

struct ChatResponseDTO: Content {
    let reply: String
}
