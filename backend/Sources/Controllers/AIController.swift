import Vapor
import Foundation
import Fluent      // 讓 Swift 認得 req.db
import FluentSQL   // 解鎖 SQLDatabase 與 \(bind:) 語法

struct AIController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let ai = routes.grouped("api", "ai")
        ai.post("chat", use: handleChat)
        ai.post("knowledge", use: addKnowledge) // 原本的單筆輸入
        ai.get("history", use: getChatHistory)
        // 新增這行：專門處理檔案上傳，並將檔案大小限制放寬到 10MB
        ai.on(.POST, "knowledge", "upload", body: .collect(maxSize: "10mb"), use: uploadKnowledge)
    }
    
    // MARK: - API: 對話生成 (Chat with RAG + 滑動窗口記憶 + Function Calling)
    @Sendable
    func handleChat(req: Request) async throws -> ChatResponseDTO {
        // 1. 確保身分並取得 User ID
        let user = try req.auth.require(UserPayload.self)
        let userID = String(user.userID)
        
        // 2. 解析前端問題
        let userRequest = try req.content.decode(ChatRequestDTO.self)
        
        let numericUserID = user.userID
        guard let currentUser = try await User.find(numericUserID, on: req.db) else {
            throw Abort(.unauthorized)
        }
        
        // 3. 判斷要撈哪個病患的資料
        var targetPatientID = numericUserID
        if currentUser.role == 1 { // 如果發問的是照護者，去查他綁定的病患
            if let bond = try await UserBond.query(on: req.db).filter(\.$caregiverID == numericUserID).first() {
                targetPatientID = bond.patientID
            }
        }
        
        // 4. 撈出該病患最近 7 天內的留言，且排除照護者專屬私密留言
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let recentMoods = try await DailyRecord.query(on: req.db)
            .filter(\.$userID == targetPatientID)
            .filter(\.$isCaregiverOnly == false)
            .filter(\.$date >= sevenDaysAgo)
            .sort(\.$date, .descending)
            .limit(5)
            .all()
        
        var dynamicPatientContext = "病患近期無特別留言。"
        if !recentMoods.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd"
            dynamicPatientContext = recentMoods.map { record in
                let dateString = formatter.string(from: record.date)
                let mood = record.moodName ?? "無特別心情"
                return "於 \(dateString) 留言:「\(record.content)」(當下心情: \(mood))"
            }.joined(separator: "\n")
        }
        
        // 儲存使用者的提問
        let newUserMsg = ChatHistory(userID: userID, role: "user", content: userRequest.message)
        try await newUserMsg.save(on: req.db)
        
        // 撈取最新 6 筆歷史對話
        let recentHistory = try await ChatHistory.query(on: req.db)
            .filter(\.$userID == userID)
            .sort(\.$createdAt, .descending)
            .limit(6)
            .all()
            .reversed()
        
        // 5. RAG 知識庫檢索
        let questionVector = try await generateEmbedding(for: userRequest.message, req: req)
        let vectorString = "[" + questionVector.map { String($0) }.joined(separator: ",") + "]"
        
        guard let sqlDB = req.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "資料庫連線異常，無法執行向量搜尋")
        }
        
        let searchResults = try await sqlDB.raw("""
                                SELECT content 
                                FROM knowledge_base 
                                ORDER BY embedding <=> \(bind: vectorString)::vector 
                                LIMIT 3
                            """).all()
        
        var retrievedContext = ""
        for (index, row) in searchResults.enumerated() {
            if let content = try? row.decode(column: "content", as: String.self) {
                retrievedContext += "[參考資料 \(index + 1)]\n\(content)\n\n"
            }
        }
        
        // 6. 準備 OpenAI 請求設定 (優化快取機制)
        guard let rawApiKey = Environment.get("OPENAI_API_KEY") else {
            throw Abort(.internalServerError, reason: "後端未配置 AI 金鑰")
        }
        let apiKey = rawApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let openAIURL = "https://api.openai.com/v1/chat/completions"
        
        // 🌟 6-1. 靜態系統提示詞 (永遠不變，放在最前面，完美吃快取)
        let staticSystemPrompt = """
                【系統最高指引：你是專屬的「帕金森氏症防手抖手套與照護 App 助手（小安）」】
                
                回答原則：
                1. 具備同理心與記憶連貫性。
                2. 若使用者詢問手抖狀況、頻率、振幅或週報，請務必主動使用工具（Tool）查詢最新數據來回答！
                3. 字數嚴格限制在 150-200 字以內。
                4. 涉及醫療建議時請加上強制安全宣告。
                """
        
        var openaiMessages: [OpenAIChatRequest.Message] = [
            .init(role: "system", content: staticSystemPrompt, tool_calls: nil, tool_call_id: nil)
        ]
        
        // 🌟 6-2. 放入歷史對話 (通常使用者的對話習慣不會突變，前面的對話也能吃快取)
        for chat in recentHistory {
            openaiMessages.append(.init(role: chat.role, content: chat.content, tool_calls: nil, tool_call_id: nil))
        }
        
        // 🌟 6-3. 動態資料注入 (會一直改變的資料，打包在最後一筆 User 訊息中)
        let dynamicUserMessage = """
                【🧠 病患近期動態上下文】
                以下是病患最近 7 天內的公開留言板紀錄：
                \(dynamicPatientContext)
                ---
                
                以下是你從知識庫中檢索到的【參考資料】：
                \(retrievedContext.isEmpty ? "目前知識庫中無相關資料。" : retrievedContext)
                ---
                
                【使用者的問題】
                \(userRequest.message)
                """
        
        // 將組合好的變動資料，作為使用者本次的提問傳送
        openaiMessages.append(.init(role: "user", content: dynamicUserMessage, tool_calls: nil, tool_call_id: nil))        // 🧰 7. 定義小安可以使用的工具箱 (宣告 API 規格給 AI 看)
        let tremorTool = OpenAIChatRequest.Tool(
            function: .init(
                name: "get_tremor_report",
                description: "獲取病患最近七天的震顫頻率與振幅週報數據，當使用者詢問手抖狀況時必須呼叫此工具",
                parameters: .init(type: "object", properties: [:])
            )
        )
        let medicationTool = OpenAIChatRequest.Tool(
            function: .init(
                name: "get_medication_records",
                description: "獲取病患的用藥紀錄，當使用者詢問吃藥、藥品名稱、服藥時間或漏吃藥時必須呼叫此工具",
                parameters: .init(type: "object", properties: [:])
            )
        )
        
        var requestBody = OpenAIChatRequest(
            model: "gpt-4o-mini",
            messages: openaiMessages,
            tools: [tremorTool, medicationTool]
        )
        
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        
        // 第一次請求 OpenAI
        let clientResponse = try await req.client.post(URI(string: openAIURL), headers: headers) {
            try $0.content.encode(requestBody, as: .json)
        }
        
        guard clientResponse.status == .ok else {
            throw Abort(.badGateway, reason: "AI 陪伴助手暫時忙碌中")
        }
        
        let openAIResponse = try clientResponse.content.decode(OpenAIChatResponse.self)
        guard let choice = openAIResponse.choices.first else {
            throw Abort(.internalServerError, reason: "生成回應失敗")
        }
        
        // ==========================================
        // 🔄 8. 關鍵雙向循環：檢查 AI 是否想呼叫工具 (Function Calling)
        // ==========================================
        if choice.finish_reason == "tool_calls", let toolCalls = choice.message.tool_calls {
            // 把 AI 想調用工具的意圖加進對話紀錄中
            openaiMessages.append(.init(
                role: "assistant",
                content: choice.message.content,
                tool_calls: toolCalls,
                tool_call_id: nil
            ))
            
            for toolCall in toolCalls {
                if toolCall.function.name == "get_tremor_report" {
                    // 執行原本的週報查詢邏輯
                    let records = try await TremorAnalysisRecord.query(on: req.db)
                        .filter(\.$userID == targetPatientID)
                        .filter(\.$recordedAt >= sevenDaysAgo)
                        .filter(\.$dataValid == true)
                        .sort(\.$recordedAt, .ascending)
                        .all()
                    
                    let calendar = Calendar.current
                    let groupedByDate = Dictionary(grouping: records) { record in
                        calendar.startOfDay(for: record.recordedAt)
                    }
                    
                    var reportSummary = "查無近期震顫數據。"
                    if !groupedByDate.isEmpty {
                        let summaries = groupedByDate.map { (date, dayRecords) in
                            let freqs = dayRecords.compactMap { $0.dominantFrequencyHz }
                            let amps = dayRecords.compactMap { $0.tremorStrengthRmsDps }
                            let avgFreq = freqs.isEmpty ? 0 : freqs.reduce(0, +) / Double(freqs.count)
                            let avgAmp = amps.isEmpty ? 0 : amps.reduce(0, +) / Double(amps.count)
                            return "日期: \(date), 平均頻率: \(String(format: "%.1f", avgFreq)) Hz, 平均振幅: \(String(format: "%.1f", avgAmp)) dps"
                        }
                        reportSummary = summaries.joined(separator: "\n")
                    }
                    
                    openaiMessages.append(.init(
                        role: "tool",
                        content: reportSummary,
                        tool_calls: nil,
                        tool_call_id: toolCall.id
                    ))
                    
                } else if toolCall.function.name == "get_medication_records" {
                    // 💊 查詢該病患的用藥紀錄
                    let meds = try await MedicationRecord.query(on: req.db)
                        .filter(\.$userID == targetPatientID)
                        .sort(\.$date, .descending)
                        .limit(10)
                        .all()
                    
                    var medSummary = "查無近期用藥紀錄。"
                    if !meds.isEmpty {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "MM/dd"
                        
                        medSummary = meds.map { med in
                            let dateString = formatter.string(from: med.date)
                            // 📝 基本資訊
                            var info = "日期: \(dateString), 藥品: \(med.name), 劑量: \(med.dose), 類型: \(med.medType)"
                            
                            // 🩹 如果有貼附部位，提供給 AI
                            if let region = med.patchRegion, !region.isEmpty {
                                info += ", 貼附部位: \(region)"
                            }
                            
                            // 🩹 如果有皮膚狀況，提供給 AI
                            if let skin = med.skinCondition, !skin.isEmpty {
                                info += ", 皮膚狀況: \(skin)"
                            }
                            
                            return info
                        }.joined(separator: "\n")
                    }
                    
                    openaiMessages.append(.init(
                        role: "tool",
                        content: medSummary,
                        tool_calls: nil,
                        tool_call_id: toolCall.id
                    ))
                }
            }
            
            // 帶著工具查詢結果，再次發送請求給 OpenAI 進行最終統整回覆
            requestBody.messages = openaiMessages
            requestBody.tools = nil // 第二次請求可以把工具欄拿掉
            
            let secondResponse = try await req.client.post(URI(string: openAIURL), headers: headers) {
                try $0.content.encode(requestBody, as: .json)
            }
            
            let secondOpenAIResponse = try secondResponse.content.decode(OpenAIChatResponse.self)
            guard let finalReply = secondOpenAIResponse.choices.first?.message.content else {
                throw Abort(.internalServerError, reason: "工具數據統整失敗")
            }
            
            let newAiMsg = ChatHistory(userID: userID, role: "assistant", content: finalReply)
            try await newAiMsg.save(on: req.db)
            return ChatResponseDTO(reply: finalReply)
        }
        
        // 如果 AI 沒有調用工具，直接回傳一般對話結果
        guard let aiReply = choice.message.content else {
            throw Abort(.internalServerError, reason: "生成回應失敗")
        }
        
        let newAiMsg = ChatHistory(userID: userID, role: "assistant", content: aiReply)
        try await newAiMsg.save(on: req.db)
        
        return ChatResponseDTO(reply: aiReply)
    }
    
    // MARK: - API: 新增知識到向量資料庫 (Knowledge Ingestion)
    @Sendable
    func addKnowledge(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(AddKnowledgeDTO.self)
        
        let vector = try await generateEmbedding(for: input.content, req: req)
        
        let knowledge = KnowledgeBase(
            category: input.category,
            content: input.content,
            embedding: vector
        )
        try await knowledge.save(on: req.db)
        
        return .ok
    }
    // MARK: - API: 批次檔案上傳建檔 (Batch Ingestion)
    @Sendable
    func uploadKnowledge(req: Request) async throws -> HTTPStatus {
        // 1. 定義接收上傳檔案的資料結構
        
        let input = try req.content.decode(UploadKnowledgeDTO.self)
        let fileName = input.file.filename.lowercased()
        let fileBuffer = input.file.data
        
        // ==========================================
        // 處理 .TXT 檔案 (單篇長文)
        // ==========================================
        if fileName.hasSuffix(".txt") {
            guard let textContent = fileBuffer.getString(at: 0, length: fileBuffer.readableBytes) else {
                throw Abort(.badRequest, reason: "無法讀取 TXT 檔案內容")
            }
            
            let category = input.category ?? "未分類"
            let vector = try await generateEmbedding(for: textContent, req: req)
            
            let knowledge = KnowledgeBase(
                category: category,
                content: textContent,
                embedding: vector
            )
            try await knowledge.save(on: req.db)
            
            req.logger.info("📄 TXT 檔案建檔成功：\(fileName)")
            
            // ==========================================
            // 處理 .JSON 檔案 (多筆批次建檔)
            // ==========================================
        } else if fileName.hasSuffix(".json") {
            // 預期上傳的 JSON 是一個陣列：[{"category": "...", "content": "..."}]
            
            let data = Data(buffer: fileBuffer)
            let batch: [BatchKnowledgeDTO]
            
            do {
                batch = try JSONDecoder().decode([BatchKnowledgeDTO].self, from: data)
            } catch {
                throw Abort(.badRequest, reason: "JSON 格式錯誤，必須是陣列格式：[{\"category\":\"...\", \"content\":\"...\"}]")
            }
            
            // 跑迴圈，將陣列中的每一篇文章都轉換為向量並存入資料庫
            for item in batch {
                let vector = try await generateEmbedding(for: item.content, req: req)
                let knowledge = KnowledgeBase(
                    category: item.category,
                    content: item.content,
                    embedding: vector
                )
                try await knowledge.save(on: req.db)
            }
            
            req.logger.info("JSON 批次建檔成功：\(fileName)，共匯入 \(batch.count) 筆知識。")
            
        } else {
            throw Abort(.badRequest, reason: "僅支援上傳 .txt 與 .json 格式的檔案")
        }
        
        return .ok
    }
    
    // MARK: - 輔助函式：將文字轉換為向量 (OpenAI Embedding)
    @Sendable
    func generateEmbedding(for text: String, req: Request) async throws -> [Float] {
        guard let rawApiKey = Environment.get("OPENAI_API_KEY") else {
            throw Abort(.internalServerError, reason: "後端未配置 OpenAI 金鑰")
        }
        let apiKey = rawApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let url = "https://api.openai.com/v1/embeddings"
        let requestBody = OpenAIEmbeddingRequest(input: text)
        
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        
        let response = try await req.client.post(URI(string: url), headers: headers) { clientReq in
            try clientReq.content.encode(requestBody, as: .json)
        }
        
        guard response.status == .ok else {
            let errorBody = response.body?.getString(at: 0, length: response.body?.readableBytes ?? 0) ?? "無錯誤內文"
            req.logger.error("OpenAI Embedding API 失敗：\(errorBody)")
            throw Abort(.internalServerError, reason: "向量化文字失敗")
        }
        
        let embeddingResponse = try response.content.decode(OpenAIEmbeddingResponse.self)
        
        guard let vector = embeddingResponse.data.first?.embedding else {
            throw Abort(.internalServerError, reason: "無法解析 OpenAI 向量格式")
        }
        
        return vector
    }
    // MARK: - API: 取得使用者的歷史對話紀錄 (給前端 App 載入聊天室畫面用)
    @Sendable
    func getChatHistory(req: Request) async throws -> [ChatHistoryResponseDTO] {
        let user = try req.auth.require(UserPayload.self)
        let userID = String(user.userID)
        
        // 撈取該使用者的歷史對話（依時間由舊到新排序，方便前端由上往下渲染）
        let history = try await ChatHistory.query(on: req.db)
            .filter(\.$userID == userID)
            .sort(\.$createdAt, .ascending)
            .all()
        
        return history.map { chat in
            ChatHistoryResponseDTO(
                id: chat.id,
                role: chat.role,
                content: chat.content,
                createdAt: chat.createdAt
            )
        }
    }
}

