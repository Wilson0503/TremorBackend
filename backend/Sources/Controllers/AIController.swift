import Vapor
import Foundation
import Fluent
import FluentSQL

struct AIController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let ai = routes.grouped("api", "ai")
        ai.post("chat", use: handleChat)
        ai.post("knowledge", use: addKnowledge)
        ai.get("history", use: getChatHistory)
        ai.on(.POST, "knowledge", "upload", body: .collect(maxSize: "10mb"), use: uploadKnowledge)
    }

    // MARK: - 🔒 核心輔助函式：動態判斷目標病患 ID (支援照護者代辦)
    private func getTargetPatientID(req: Request, currentUserID: Int) async throws -> Int {
        guard let currentUser = try await User.find(currentUserID, on: req.db) else {
            throw Abort(.notFound, reason: "找不到您的使用者帳號")
        }
        if currentUser.role == 1 {
            guard let bond = try await UserBond.query(on: req.db)
                .filter(\.$caregiverID == currentUserID)
                .first() else {
                throw Abort(.notFound, reason: "目前尚未綁定任何被照護者")
            }
            return bond.patientID
        }
        return currentUserID
    }

    // MARK: - API: 對話生成 (Agent with RAG + Action State Mutation + Bounded Loop)
    @Sendable
    func handleChat(req: Request) async throws -> ChatResponseDTO {
        let user = try req.auth.require(UserPayload.self)
        let userID = String(user.userID)
        let userRequest = try req.content.decode(ChatRequestDTO.self)
        
        let targetPatientID = try await getTargetPatientID(req: req, currentUserID: user.userID)

        let taipeiTimeZone = TimeZone(identifier: "Asia/Taipei") ?? TimeZone(secondsFromGMT: 8 * 3600)!

        // 1. 撈取病患最近 7 天內的留言板紀錄
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let recentMoods = try await DailyRecord.query(on: req.db)
            .filter(\.$userID == targetPatientID)
            .filter(\.$isCaregiverOnly == false)
            .filter(\.$date >= sevenDaysAgo)
            .sort(\.$date, .descending)
            .limit(5)
            .all()

        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = taipeiTimeZone
        dateFormatter.dateFormat = "MM/dd HH:mm"
        
        var dynamicPatientContext = "病患近期無特別留言。"
        if !recentMoods.isEmpty {
            dynamicPatientContext = recentMoods.map { record in
                let dateString = dateFormatter.string(from: record.date)
                let mood = record.moodName ?? "無特別心情"
                return "[\(dateString)] 「\(record.content)」(心情: \(mood))"
            }.joined(separator: "\n")
        }

        // 2. 先撈取最新 6 筆歷史對話以維持滑動窗口記憶
        let recentHistory = try await ChatHistory.query(on: req.db)
            .filter(\.$userID == userID)
            .sort(\.$createdAt, .descending)
            .limit(6)
            .all()
            .reversed()

        // 3. 儲存使用者本次提問至歷史紀錄
        let newUserMsg = ChatHistory(userID: userID, role: "user", content: userRequest.message)
        try await newUserMsg.save(on: req.db)

        // 4. RAG 向量檢索
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

        // 5. 準備 OpenAI 請求
        guard let rawApiKey = Environment.get("OPENAI_API_KEY") else {
            throw Abort(.internalServerError, reason: "後端未配置 OPENAI_API_KEY 金鑰")
        }
        let apiKey = rawApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let openAIURL = "https://api.openai.com/v1/chat/completions"

        // 🌟 5-1. 靜態系統提示詞
        let staticSystemPrompt = """
        【系統最高指引：你是專屬的「帕金森氏症防手抖手套與照護 App 智慧助理（小安）」】

        核心角色與行動指引：
        1. 語氣溫暖、具同理心，回答精簡聚焦在 150-200 字以內。
        2. 你具備「代辦執行能力」，能直接替使用者操作 App 寫入資料庫：
           - 使用者表示「吃了藥」或「貼了貼布」➔ 呼叫 `add_medication_record`
           - 使用者表示「想新增用藥提醒/排程」➔ 呼叫 `create_medication_plan`
           - 使用者表示「想留言/貼便利貼/記錄心情」➔ 呼叫 `add_daily_note`
           - 使用者表示「身體不適/手抖加劇/肢體僵硬等症狀」➔ 呼叫 `add_symptom_record`
           - 使用者詢問「震顫數據/週報」➔ 呼叫 `get_tremor_report`
           - 使用者詢問「吃了什麼藥/用藥歷史」➔ 呼叫 `get_medication_records`
        3. 【防呆防幻覺嚴格守則】：
           - 若使用者說「我剛吃藥了」但未提供「藥名」或「劑量」，【嚴禁】胡亂猜測寫入！請溫柔反問使用者服用哪種藥品與數量。
           - 若提及特定時間（如「昨天下午2點」、「剛剛」），請務必對照【當前系統時間】正確換算為 yyyy-MM-dd HH:mm 格式傳入工具。
           - 代辦工具執行完成後，請給予溫馨確認（包含日期與時間），切勿將系統 ID 暴露給使用者。
        4. 涉及醫療劑量調整建議時，一律加上安全宣告並提醒遵從專科醫師醫囑。
        """

        var openaiMessages: [OpenAIChatRequest.Message] = [
            .init(role: "system", content: staticSystemPrompt, tool_calls: nil, tool_call_id: nil)
        ]

        for chat in recentHistory {
            openaiMessages.append(.init(role: chat.role, content: chat.content, tool_calls: nil, tool_call_id: nil))
        }

        // 🌟 5-2. 動態上下文注入
        let nowFormatter = DateFormatter()
        nowFormatter.timeZone = taipeiTimeZone
        nowFormatter.dateFormat = "yyyy-MM-dd HH:mm (EEEE)"
        let currentTimeString = nowFormatter.string(from: Date())

        let dynamicUserMessage = """
        【當前系統時間】\(currentTimeString)
        【病患近期動態紀錄】
        \(dynamicPatientContext)
        ---
        【檢索知識庫參考資料】
        \(retrievedContext.isEmpty ? "知識庫中無直接相關資料。" : retrievedContext)
        ---
        【使用者本輪提問/指令】
        \(userRequest.message)
        """

        openaiMessages.append(.init(role: "user", content: dynamicUserMessage, tool_calls: nil, tool_call_id: nil))

        // 🧰 6. 定義工具箱 (強化時間格式為 yyyy-MM-dd HH:mm)
        let tools: [OpenAIChatRequest.Tool] = [
            .init(function: .init(
                name: "get_tremor_report",
                description: "獲取病患最近七天的震顫頻率與振幅週報數據",
                parameters: .init(type: "object", properties: [:], required: [])
            )),
            .init(function: .init(
                name: "get_medication_records",
                description: "獲取病患最近的實際用藥歷史紀錄",
                parameters: .init(type: "object", properties: [:], required: [])
            )),
            .init(function: .init(
                name: "add_medication_record",
                description: "登記一筆實際服藥或貼片紀錄。若缺少藥名或劑量請勿呼叫，先向使用者追問。",
                parameters: .init(
                    type: "object",
                    properties: [
                        "name": .init(type: "string", description: "藥品名稱，例如：美道普、利福全、紐普羅貼片"),
                        "dose": .init(type: "string", description: "服藥劑量，例如：1顆、半顆、2mg/24hr"),
                        "medType": .init(type: "string", description: "類型：口服藥、貼布、水劑，預設口服藥"),
                        "patchRegion": .init(type: "string", description: "若為貼布，請填寫貼附部位（例如：左肩、右上臂）"),
                        "skinCondition": .init(type: "string", description: "若為貼布，皮膚狀況描述（例如：正常、輕微發紅）"),
                        "recordedAt": .init(type: "string", description: "服藥或貼片的精確日期時間，格式固定為「yyyy-MM-dd HH:mm」（例如 2026-08-25 14:00）。請依【當前系統時間】推算使用者指涉的昨天、剛才、特定時段或當前時間。")
                    ],
                    required: ["name", "dose", "recordedAt"]
                )
            )),
            .init(function: .init(
                name: "create_medication_plan",
                description: "建立長期的用藥排程提醒清單",
                parameters: .init(
                    type: "object",
                    properties: [
                        "name": .init(type: "string", description: "藥品名稱"),
                        "dose": .init(type: "string", description: "每次服用劑量"),
                        "timeSlotsRaw": .init(type: "string", description: "提醒時段，逗號分隔，例如 08:00,12:00,18:00"),
                        "repeatFrequency": .init(type: "string", description: "重複頻率，預設為「每天」"),
                        "medType": .init(type: "string", description: "藥品類型，預設為「口服藥」")
                    ],
                    required: ["name", "dose", "timeSlotsRaw"]
                )
            )),
            .init(function: .init(
                name: "add_daily_note",
                description: "在心情留言板發布一張便利貼",
                parameters: .init(
                    type: "object",
                    properties: [
                        "content": .init(type: "string", description: "留言內容"),
                        "moodName": .init(type: "string", description: "當下心情（例如：開心、平靜、焦慮、疲累、不舒服）")
                    ],
                    required: ["content"]
                )
            )),
            .init(function: .init(
                name: "add_symptom_record",
                description: "記錄病患突發或觀察到的異常肢體表徵與症狀",
                parameters: .init(
                    type: "object",
                    properties: [
                        "symptomNote": .init(type: "string", description: "症狀描述（例如：右手大拇指靜止抖動劇烈、步態凍結起步困難）"),
                        "recordedAt": .init(type: "string", description: "症狀發生日期時間，格式固定為「yyyy-MM-dd HH:mm」，請依【當前系統時間】推算。")
                    ],
                    required: ["symptomNote"]
                )
            ))
        ]

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Authorization", value: "Bearer \(apiKey)")

        // 🔄 7. 有界狀態機迴圈
        var finalReply: String = "抱歉，目前無法產生回覆。"

        for turn in 1...2 {
            let requestBody = OpenAIChatRequest(
                model: "gpt-4o-mini",
                messages: openaiMessages,
                tools: (turn == 2 ? nil : tools)
            )

            let clientResponse = try await req.client.post(URI(string: openAIURL), headers: headers) {
                try $0.content.encode(requestBody, as: .json)
            }

            guard clientResponse.status == .ok else {
                throw Abort(.badGateway, reason: "AI 服務暫時無法連線")
            }

            let openAIResponse = try clientResponse.content.decode(OpenAIChatResponse.self)
            guard let choice = openAIResponse.choices.first else {
                throw Abort(.internalServerError, reason: "生成回應失敗")
            }

            if choice.finish_reason != "tool_calls" || choice.message.tool_calls == nil {
                finalReply = choice.message.content ?? ""
                break
            }

            let toolCalls = choice.message.tool_calls!
            openaiMessages.append(.init(
                role: "assistant",
                content: choice.message.content,
                tool_calls: toolCalls,
                tool_call_id: nil
            ))

            for toolCall in toolCalls {
                let toolResult = try await executeToolCall(
                    toolCall: toolCall,
                    targetPatientID: targetPatientID,
                    req: req
                )
                openaiMessages.append(.init(
                    role: "tool",
                    content: toolResult,
                    tool_calls: nil,
                    tool_call_id: toolCall.id
                ))
            }
        }

        // 8. 儲存 AI 回覆至歷史對話
        let newAiMsg = ChatHistory(userID: userID, role: "assistant", content: finalReply)
        try await newAiMsg.save(on: req.db)

        return ChatResponseDTO(reply: finalReply)
    }

    // MARK: - 🛠️ 工具執行引擎 (Tool Execution Dispatcher)
    private func executeToolCall(
        toolCall: ToolCall,
        targetPatientID: Int,
        req: Request
    ) async throws -> String {
        let name = toolCall.function.name
        let argsData = toolCall.function.arguments.data(using: .utf8) ?? Data()
        let taipeiTimeZone = TimeZone(identifier: "Asia/Taipei") ?? TimeZone(secondsFromGMT: 8 * 3600)!

        switch name {
        case "get_tremor_report":
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            let records = try await TremorAnalysisRecord.query(on: req.db)
                .filter(\.$userID == targetPatientID)
                .filter(\.$recordedAt >= sevenDaysAgo)
                .filter(\.$dataValid == true)
                .sort(\.$recordedAt, .ascending)
                .all()

            let calendar = Calendar.current
            let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.recordedAt) }
            if grouped.isEmpty { return "查無最近 7 天的震顫量測數據。" }

            let summaries = grouped.map { (date, dayRecords) in
                let freqs = dayRecords.compactMap { $0.dominantFrequencyHz }
                let amps = dayRecords.compactMap { $0.tremorStrengthRmsDps }
                let avgF = freqs.isEmpty ? 0 : freqs.reduce(0, +) / Double(freqs.count)
                let avgA = amps.isEmpty ? 0 : amps.reduce(0, +) / Double(amps.count)
                let dateStr = DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none)
                return "\(dateStr): 平均頻率 \(String(format: "%.1f", avgF)) Hz, 震顫強度 \(String(format: "%.2f", avgA)) dps"
            }
            return summaries.joined(separator: "\n")

        case "get_medication_records":
            let meds = try await MedicationRecord.query(on: req.db)
                .filter(\.$userID == targetPatientID)
                .sort(\.$date, .descending)
                .limit(8)
                .all()
            if meds.isEmpty { return "查無用藥紀錄。" }
            let formatter = DateFormatter()
            formatter.timeZone = taipeiTimeZone
            formatter.dateFormat = "yyyy/MM/dd HH:mm"
            return meds.map { "[\(formatter.string(from: $0.date))] \($0.name) (\($0.dose)) - \($0.medType)" }.joined(separator: "\n")

        case "add_medication_record":
            struct AddMedArgs: Decodable {
                let name: String
                let dose: String
                let medType: String?
                let patchRegion: String?
                let skinCondition: String?
                let recordedAt: String?
            }
            guard let args = try? JSONDecoder().decode(AddMedArgs.self, from: argsData) else {
                return "參數解析失敗。"
            }
            
            var recordDate = Date()
            if let dateStr = args.recordedAt {
                let formatter = DateFormatter()
                formatter.timeZone = taipeiTimeZone
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                if let parsedDate = formatter.date(from: dateStr) {
                    recordDate = parsedDate
                }
            }

            let newRecord = MedicationRecord(
                userID: targetPatientID,
                date: recordDate,
                name: args.name,
                dose: args.dose,
                medType: args.medType ?? "口服藥",
                patchRegion: args.patchRegion,
                skinCondition: args.skinCondition,
                skinImageDataList: []
            )
            try await newRecord.save(on: req.db)

            let outFormatter = DateFormatter()
            outFormatter.timeZone = taipeiTimeZone
            outFormatter.dateFormat = "yyyy/MM/dd HH:mm"
            return "✅ 成功登記用藥：\(args.name) (\(args.dose))，時間：\(outFormatter.string(from: recordDate))。"

        case "create_medication_plan":
            struct CreatePlanArgs: Decodable {
                let name: String
                let dose: String
                let timeSlotsRaw: String
                let repeatFrequency: String?
                let medType: String?
            }
            guard let args = try? JSONDecoder().decode(CreatePlanArgs.self, from: argsData) else {
                return "排程參數解析失敗。"
            }

            let newPlan = MedicationPlan(
                userID: targetPatientID,
                name: args.name,
                dose: args.dose,
                medType: args.medType ?? "口服藥",
                timeSlotsRaw: args.timeSlotsRaw,
                startDate: Date(),
                repeatFrequency: args.repeatFrequency ?? "每天"
            )
            try await newPlan.save(on: req.db)
            return "✅ 成功建立長期用藥排程：\(args.name)，時段 [\(args.timeSlotsRaw)]。"

        case "add_daily_note":
            struct AddNoteArgs: Decodable {
                let content: String
                let moodName: String?
            }
            guard let args = try? JSONDecoder().decode(AddNoteArgs.self, from: argsData) else {
                return "留言參數解析失敗。"
            }

            let newNote = DailyRecord(
                id: UUID().uuidString,
                userID: targetPatientID,
                content: args.content,
                date: Date(),
                colorHex: "#FFF9C4",
                sender: "小安助理代記",
                moodName: args.moodName ?? "日常",
                isCaregiverOnly: false
            )
            try await newNote.save(on: req.db)
            return "✅ 成功新增心情便利貼：\(args.content)。"

        case "add_symptom_record":
            struct AddSymptomArgs: Decodable {
                let symptomNote: String
                let recordedAt: String?
            }
            guard let args = try? JSONDecoder().decode(AddSymptomArgs.self, from: argsData) else {
                return "症狀參數解析失敗。"
            }

            var recordDate = Date()
            if let dateStr = args.recordedAt {
                let formatter = DateFormatter()
                formatter.timeZone = taipeiTimeZone
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                if let parsedDate = formatter.date(from: dateStr) {
                    recordDate = parsedDate
                }
            }

            let record = SymptomRecord(
                userID: targetPatientID,
                date: recordDate,
                symptomNote: args.symptomNote,
                mediaDataList: [],
                isVideo: false
            )
            try await record.save(on: req.db)
            
            let outFormatter = DateFormatter()
            outFormatter.timeZone = taipeiTimeZone
            outFormatter.dateFormat = "yyyy/MM/dd HH:mm"
            return "✅ 成功記錄表徵症狀：\(args.symptomNote)，時間：\(outFormatter.string(from: recordDate))。"

        default:
            return "未知的工具操作指令。"
        }
    }

    // MARK: - API: 新增單筆知識
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

    // MARK: - API: 批次檔案上傳建檔 (.txt / .json)
    @Sendable
    func uploadKnowledge(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(UploadKnowledgeDTO.self)
        let fileName = input.file.filename.lowercased()
        let fileBuffer = input.file.data

        if fileName.hasSuffix(".txt") {
            guard let textContent = fileBuffer.getString(at: 0, length: fileBuffer.readableBytes) else {
                throw Abort(.badRequest, reason: "無法讀取 TXT 檔案內容")
            }
            let category = input.category ?? "未分類"
            let vector = try await generateEmbedding(for: textContent, req: req)
            let knowledge = KnowledgeBase(category: category, content: textContent, embedding: vector)
            try await knowledge.save(on: req.db)
        } else if fileName.hasSuffix(".json") {
            let data = Data(buffer: fileBuffer)
            guard let batch = try? JSONDecoder().decode([BatchKnowledgeDTO].self, from: data) else {
                throw Abort(.badRequest, reason: "JSON 格式錯誤，需為 [{\"category\":\"...\", \"content\":\"...\"}] 陣列")
            }
            for item in batch {
                let vector = try await generateEmbedding(for: item.content, req: req)
                let knowledge = KnowledgeBase(category: item.category, content: item.content, embedding: vector)
                try await knowledge.save(on: req.db)
            }
        } else {
            throw Abort(.badRequest, reason: "僅支援上傳 .txt 與 .json 格式檔案")
        }
        return .ok
    }

    // MARK: - 輔助函式：OpenAI Text-Embedding-3-Small 向量轉換
    @Sendable
    func generateEmbedding(for text: String, req: Request) async throws -> [Float] {
        guard let rawApiKey = Environment.get("OPENAI_API_KEY") else {
            throw Abort(.internalServerError, reason: "後端未配置 OPENAI_API_KEY 金鑰")
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
            throw Abort(.internalServerError, reason: "向量化文字失敗")
        }

        let embeddingResponse = try response.content.decode(OpenAIEmbeddingResponse.self)
        guard let vector = embeddingResponse.data.first?.embedding else {
            throw Abort(.internalServerError, reason: "無法解析 OpenAI 向量格式")
        }
        return vector
    }

    // MARK: - API: 取得歷史對話紀錄
    @Sendable
    func getChatHistory(req: Request) async throws -> [ChatHistoryResponseDTO] {
        let user = try req.auth.require(UserPayload.self)
        let userID = String(user.userID)

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
