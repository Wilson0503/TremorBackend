//
//  AIController.swift
//

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
        ai.post("consultation-summary", use: generateConsultationSummary)
        ai.get("consultation-preparation", use: getConsultationPreparation)
        ai.put("consultation-preparation", use: saveConsultationPreparation)
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
    
    // MARK: - 🔑 輔助函式：取得 OpenAI 金鑰與驗證標頭
    private func getOpenAIHeaders() throws -> (apiKey: String, headers: HTTPHeaders) {
        guard let rawApiKey = Environment.get("OPENAI_API_KEY") else {
            throw Abort(.internalServerError, reason: "後端未配置 OPENAI_API_KEY 金鑰")
        }
        let apiKey = rawApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        return (apiKey, headers)
    }
    
    // MARK: - API: 對話生成 (Agent with RAG + Action State Mutation + Bounded Loop)
    @Sendable
    func handleChat(req: Request) async throws -> Response { // 🔥 改為回傳 Response
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
        
        // 2. 撈取最新 6 筆歷史對話維持記憶窗口
        let recentHistory = try await ChatHistory.query(on: req.db)
            .filter(\.$userID == userID)
            .sort(\.$createdAt, .descending)
            .limit(6)
            .all()
            .reversed()
        
        // 3. 儲存使用者提問
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
        let auth = try getOpenAIHeaders()
        let openAIURL = "https://api.openai.com/v1/chat/completions"
        
        let staticSystemPrompt = """
            【系統最高指引：你是專屬的「帕金森氏症防手抖手套與照護 App 智慧助理（小安）」】
            
            核心角色與行動指引：
            1. 語氣溫暖、具同理心，回答精簡聚焦在 200-300 字以內，善用條列方式提供易讀的摘要。
            2. 你具備「代辦與數據統整執行能力」，能直接替使用者操作 App 寫入資料庫或查詢數據：
               - 使用者表示「吃了藥」或「貼了貼布」➔ 呼叫 `add_medication_record`
               - 使用者表示「想新增用藥提醒/排程」➔ 呼叫 `create_medication_plan`
               - 使用者表示「想留言/貼便利貼/記錄心情」➔ 呼叫 `add_daily_note`
               - 使用者表示「身體不適/手抖加劇/肢體僵硬等症狀」➔ 呼叫 `add_symptom_record`
               - 使用者要求「產生週報/統整本週數據/回顧最近狀況」➔ 呼叫 `get_weekly_health_summary`
               - 使用者詢問「吃了什麼藥/用藥歷史」➔ 呼叫 `get_medication_records`
            3. 【用藥遵從度與自評週報分析原則】：
               - 若發現使用者有「漏服排程藥物」或「服用了非排程清單上的額外藥品」，請在週報中以溫和關心的語氣進行提醒。
               - 結合手抖震顫變化、生理指標、每日症狀自評量表、突發異常症狀與心情留言進行綜合分析。
            4. 【防呆防幻覺嚴格守則】：
               - 若使用者說「我剛吃藥了」但未提供「藥名」或「劑量」，【嚴禁】胡亂猜測寫入！請溫柔反問使用者服用哪種藥品與數量。
               - 涉及醫療劑量調整建議時，一律加上安全宣告並提醒遵從專科醫師醫囑。
            """
        
        var openaiMessages: [OpenAIChatRequest.Message] = [
            .init(role: "system", content: staticSystemPrompt, tool_calls: nil, tool_call_id: nil)
        ]
        
        for chat in recentHistory {
            openaiMessages.append(.init(role: chat.role, content: chat.content, tool_calls: nil, tool_call_id: nil))
        }
        
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
        
        let tools: [OpenAIChatRequest.Tool] = [
            .init(function: .init(
                name: "get_weekly_health_summary",
                description: "獲取病患近 7 天全方位健康週報：涵蓋震顫數據平均、生理指標、用藥排程與實際服藥對比（包含漏服與非排程用藥分析）、每日自評量表得分、突發異常表徵及心情留言",
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
                        "recordedAt": .init(type: "string", description: "服藥或貼片的精確日期時間，格式固定為「yyyy-MM-dd HH:mm」")
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
                        "recordedAt": .init(type: "string", description: "症狀發生日期時間，格式固定為「yyyy-MM-dd HH:mm」")
                    ],
                    required: ["symptomNote"]
                )
            ))
        ]
        
        var finalReply: String = "抱歉，目前無法產生回覆。"
        
        for turn in 1...2 {
            let requestBody = OpenAIChatRequest(
                model: "gpt-4o-mini",
                messages: openaiMessages,
                tools: (turn == 2 ? nil : tools)
            )
            
            let clientResponse = try await req.client.post(URI(string: openAIURL), headers: auth.headers) {
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
        
        let newAiMsg = ChatHistory(userID: userID, role: "assistant", content: finalReply)
        try await newAiMsg.save(on: req.db)
        
        // 🔥 取得保存後的時間戳記，並使用 ISO8601 編碼輸出
        let replyTime = newAiMsg.createdAt ?? Date()
        let responseDTO = ChatResponseDTO(reply: finalReply, createdAt: replyTime)
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(responseDTO)
        
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: body)
        )
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
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        
        switch name {
        case "get_weekly_health_summary", "get_tremor_report":
            // 🚀 效能優化：使用 async let 並行撈取 7 大資料庫表
            async let fetchTremors = TremorAnalysisRecord.query(on: req.db)
                .filter(\.$userID == targetPatientID)
                .filter(\.$recordedAt >= sevenDaysAgo)
                .filter(\.$dataValid == true)
                .all()
            
            async let fetchVitals = HealthVitalsRecord.query(on: req.db)
                .filter(\.$userID == targetPatientID)
                .filter(\.$date >= sevenDaysAgo)
                .all()
            
            async let fetchPlans = MedicationPlan.query(on: req.db)
                .filter(\.$userID == targetPatientID)
                .all()
            
            async let fetchMeds = MedicationRecord.query(on: req.db)
                .filter(\.$userID == targetPatientID)
                .filter(\.$date >= sevenDaysAgo)
                .all()
            
            async let fetchSymptoms = SymptomRecord.query(on: req.db)
                .filter(\.$userID == targetPatientID)
                .filter(\.$date >= sevenDaysAgo)
                .all()
            
            async let fetchNotes = DailyRecord.query(on: req.db)
                .filter(\.$userID == targetPatientID)
                .filter(\.$isCaregiverOnly == false)
                .filter(\.$date >= sevenDaysAgo)
                .all()
            
            async let fetchAssessments = DailyAssessmentRecord.query(on: req.db)
                .filter(\.$userID == targetPatientID)
                .filter(\.$date >= sevenDaysAgo)
                .sort(\.$date, .descending)
                .all()
            
            let (tremors, vitals, plans, meds, symptoms, dailyNotes, assessments) = try await (
                fetchTremors, fetchVitals, fetchPlans, fetchMeds, fetchSymptoms, fetchNotes, fetchAssessments
            )
            
            // 1. 震顫統計
            var tremorSummary = "【本週震顫量測】：無量測數據。"
            if !tremors.isEmpty {
                let freqs = tremors.compactMap { $0.dominantFrequencyHz }
                let amps = tremors.compactMap { $0.tremorStrengthRmsDps }
                let avgF = freqs.isEmpty ? 0 : freqs.reduce(0, +) / Double(freqs.count)
                let avgA = amps.isEmpty ? 0 : amps.reduce(0, +) / Double(amps.count)
                tremorSummary = "【本週震顫量測】：共量測 \(tremors.count) 次，平均震顫頻率 \(String(format: "%.1f", avgF)) Hz，平均震顫強度 \(String(format: "%.2f", avgA)) dps。"
            }
            
            // 2. 生理指標統計
            var vitalsSummary = "【本週生理指標】：無登記紀錄。"
            if !vitals.isEmpty {
                let sysList = vitals.compactMap { $0.systolicBP.flatMap(Double.init) }
                let diaList = vitals.compactMap { $0.diastolicBP.flatMap(Double.init) }
                let sugarList = vitals.compactMap { $0.bloodSugar.flatMap(Double.init) }
                let sleepList = vitals.compactMap { $0.sleepHours.flatMap(Double.init) }
                let weightList = vitals.compactMap { $0.bodyWeight.flatMap(Double.init) }
                
                var parts: [String] = []
                if !sysList.isEmpty && !diaList.isEmpty {
                    let avgSys = sysList.reduce(0, +) / Double(sysList.count)
                    let avgDia = diaList.reduce(0, +) / Double(diaList.count)
                    parts.append("平均血壓 \(String(format: "%.0f", avgSys))/\(String(format: "%.0f", avgDia)) mmHg")
                }
                if !sugarList.isEmpty {
                    let avgSugar = sugarList.reduce(0, +) / Double(sugarList.count)
                    parts.append("平均血糖 \(String(format: "%.1f", avgSugar)) mg/dL")
                }
                if !sleepList.isEmpty {
                    let avgSleep = sleepList.reduce(0, +) / Double(sleepList.count)
                    parts.append("平均睡眠 \(String(format: "%.1f", avgSleep)) 小時")
                }
                if !weightList.isEmpty {
                    let avgWeight = weightList.reduce(0, +) / Double(weightList.count)
                    parts.append("平均體重 \(String(format: "%.1f", avgWeight)) kg")
                }
                vitalsSummary = "【本週生理指標】：\(parts.isEmpty ? "已記錄日常生理數據" : parts.joined(separator: "，"))。"
            }
            
            // 3. 用藥排程遵從度與非排程對比
            var medSummary = "【本週用藥與排程對比】：無用藥排程與紀錄。"
            if !plans.isEmpty || !meds.isEmpty {
                var planAdherenceLines: [String] = []
                let plannedNormalizedNames = Set(plans.map {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                })
                
                for plan in plans {
                    let pName = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let pNorm = pName.lowercased()
                    let slots = plan.timeSlotsRaw.split(separator: ",").map {
                        String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty }
                    let dailySlotsCount = max(1, slots.count)
                    
                    var calendar = Calendar.current
                    calendar.timeZone = taipeiTimeZone
                    let daysSinceStart = calendar.dateComponents([.day], from: calendar.startOfDay(for: plan.startDate), to: calendar.startOfDay(for: Date())).day ?? 7
                    let activeDays = min(7, max(1, daysSinceStart + 1))
                    let expectedCount = dailySlotsCount * activeDays
                    
                    let actualCount = meds.filter {
                        $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == pNorm
                    }.count
                    
                    if actualCount < expectedCount {
                        let missed = expectedCount - actualCount
                        planAdherenceLines.append("• 藥品「\(pName)」(\(plan.dose))：近 \(activeDays) 天預期應服 \(expectedCount) 次，實際記錄 \(actualCount) 次 ➔ 疑似漏服 \(missed) 次（既定時段：\(plan.timeSlotsRaw)）")
                    } else {
                        planAdherenceLines.append("• 藥品「\(pName)」(\(plan.dose))：近 \(activeDays) 天預期應服 \(expectedCount) 次，實際記錄 \(actualCount) 次 ➔ 遵從度良好")
                    }
                }
                
                let unplannedMeds = meds.filter { rec in
                    let rNorm = rec.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return !plannedNormalizedNames.contains(rNorm)
                }
                
                var unplannedLines: [String] = []
                if !unplannedMeds.isEmpty {
                    let groupedUnplanned = Dictionary(grouping: unplannedMeds) {
                        $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    for (uName, uList) in groupedUnplanned {
                        unplannedLines.append("• 額外用藥「\(uName)」：本週累計登記 \(uList.count) 次（未在長期排程清單中）")
                    }
                }
                
                medSummary = """
                【本週用藥與排程對比分析】：
                - 既定排程遵從狀況：
                \(planAdherenceLines.isEmpty ? "  (無設定長期排程)" : planAdherenceLines.joined(separator: "\n"))
                - 非既定排程額外用藥：
                \(unplannedLines.isEmpty ? "  (無額外非排程用藥)" : unplannedLines.joined(separator: "\n"))
                """
            }
            
            // 4. 每日評估量表統計 (獨立層級)
            var assessmentSummary = "【本週每日量表自評】：本週無填寫問卷。"
            if !assessments.isEmpty {
                let avgTotal = Double(assessments.map(\.totalScore).reduce(0, +)) / Double(assessments.count)
                let avgMood = Double(assessments.map(\.moodScore).reduce(0, +)) / Double(assessments.count)
                let avgADL = Double(assessments.map(\.adlScore).reduce(0, +)) / Double(assessments.count)
                let avgMotor = Double(assessments.map(\.motorScore).reduce(0, +)) / Double(assessments.count)
                assessmentSummary = "【本週每日量表自評】：累計填寫 \(assessments.count) 次，平均總分 \(String(format: "%.1f", avgTotal)) 分（心情認知 \(String(format: "%.1f", avgMood))/16、生活自理 \(String(format: "%.1f", avgADL))/52、動作能力 \(String(format: "%.1f", avgMotor))/32）。"
            }
            
            // 5. 異常表徵
            let symptomSummary = symptoms.isEmpty ? "【本週突發症狀】：無異常回報。" : "【本週突發症狀】：共登記 \(symptoms.count) 則，症狀包含「\(symptoms.map { $0.symptomNote }.joined(separator: "；"))」。"
            
            // 6. 心情留言
            let moodSummary = dailyNotes.isEmpty ? "【本週心情留言】：無特別發文。" : "【本週心情留言】：共 \(dailyNotes.count) 則，心情以「\(dailyNotes.compactMap { $0.moodName }.joined(separator: "、"))」為主。"
            
            return """
            === 病患最近 7 天全方位健康週報數據 ===
            \(tremorSummary)
            \(vitalsSummary)
            \(medSummary)
            \(assessmentSummary)
            \(symptomSummary)
            \(moodSummary)
            """
            
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
                defaultPatchRegion: nil,
                timeSlotsRaw: args.timeSlotsRaw,
                startDate: Date(),
                repeatFrequency: args.repeatFrequency ?? "每天",
                customInterval: 1,
                customUnit: "天",
                weekdaysRaw: "",
                monthDaysRaw: ""
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
    
    // MARK: - 🌟 API: 產生看診溝通卡片摘要 (POST /api/ai/consultation-summary)
    @Sendable
    func generateConsultationSummary(req: Request) async throws -> Response {
        let user = try req.auth.require(UserPayload.self)
        let targetPatientID = try await getTargetPatientID(req: req, currentUserID: user.userID)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try req.content.decode(GenerateConsultationSummaryRequestDTO.self, using: decoder)
        
        let taipeiTimeZone = TimeZone(identifier: "Asia/Taipei") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = taipeiTimeZone
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        
        // 🚀 效能優化：使用 async let 並行撈取 7 大模組資料
        async let fetchTremors = TremorAnalysisRecord.query(on: req.db)
            .filter(\.$userID == targetPatientID)
            .filter(\.$recordedAt >= payload.startDate)
            .filter(\.$recordedAt <= payload.endDate)
            .filter(\.$dataValid == true)
            .all()
        
        async let fetchVitals = HealthVitalsRecord.query(on: req.db)
            .filter(\.$userID == targetPatientID)
            .filter(\.$date >= payload.startDate)
            .filter(\.$date <= payload.endDate)
            .all()
        
        async let fetchPlans = MedicationPlan.query(on: req.db)
            .filter(\.$userID == targetPatientID)
            .all()
        
        async let fetchMeds = MedicationRecord.query(on: req.db)
            .filter(\.$userID == targetPatientID)
            .filter(\.$date >= payload.startDate)
            .filter(\.$date <= payload.endDate)
            .all()
        
        async let fetchSymptoms = SymptomRecord.query(on: req.db)
            .filter(\.$userID == targetPatientID)
            .filter(\.$date >= payload.startDate)
            .filter(\.$date <= payload.endDate)
            .all()
        
        async let fetchMoods: [DailyRecord] = {
            if payload.includeMoodNotes {
                return try await DailyRecord.query(on: req.db)
                    .filter(\.$userID == targetPatientID)
                    .filter(\.$isCaregiverOnly == false)
                    .filter(\.$date >= payload.startDate)
                    .filter(\.$date <= payload.endDate)
                    .all()
            }
            return []
        }()
        
        async let fetchAssessments = DailyAssessmentRecord.query(on: req.db)
            .filter(\.$userID == targetPatientID)
            .filter(\.$date >= payload.startDate)
            .filter(\.$date <= payload.endDate)
            .all()
        
        let (tremors, vitals, plans, meds, symptoms, moods, assessments) = try await (
            fetchTremors, fetchVitals, fetchPlans, fetchMeds, fetchSymptoms, fetchMoods, fetchAssessments
        )
        
        // 1. 震顫上下文
        var tremorContext = "無震顫量測紀錄。"
        if !tremors.isEmpty {
            let freqs = tremors.compactMap { $0.dominantFrequencyHz }
            let amps = tremors.compactMap { $0.tremorStrengthRmsDps }
            let avgF = freqs.isEmpty ? 0 : freqs.reduce(0, +) / Double(freqs.count)
            let avgA = amps.isEmpty ? 0 : amps.reduce(0, +) / Double(amps.count)
            let highEvents = tremors.filter { ($0.tremorStrengthRmsDps ?? 0) >= 0.20 }.count
            tremorContext = "量測次數: \(tremors.count) 次，平均震顫頻率: \(String(format: "%.1f", avgF)) Hz，平均強度: \(String(format: "%.2f", avgA)) dps，中重度震顫事件次數: \(highEvents) 次。"
        }
        
        // 2. 生理指標上下文
        var vitalsContext = "無生理指標紀錄。"
        if !vitals.isEmpty {
            let sysList = vitals.compactMap { $0.systolicBP.flatMap(Double.init) }
            let diaList = vitals.compactMap { $0.diastolicBP.flatMap(Double.init) }
            let sugarList = vitals.compactMap { $0.bloodSugar.flatMap(Double.init) }
            let sleepList = vitals.compactMap { $0.sleepHours.flatMap(Double.init) }
            var vParts: [String] = []
            if !sysList.isEmpty && !diaList.isEmpty {
                vParts.append("平均血壓: \(String(format: "%.0f", sysList.reduce(0, +)/Double(sysList.count)))/\(String(format: "%.0f", diaList.reduce(0, +)/Double(diaList.count))) mmHg")
            }
            if !sugarList.isEmpty {
                vParts.append("平均血糖: \(String(format: "%.1f", sugarList.reduce(0, +)/Double(sugarList.count))) mg/dL")
            }
            if !sleepList.isEmpty {
                vParts.append("平均睡眠: \(String(format: "%.1f", sleepList.reduce(0, +)/Double(sleepList.count))) 小時")
            }
            vitalsContext = vParts.joined(separator: "，")
        }
        
        // 3. 用藥上下文
        var medContext = "無用藥資料。"
        if !plans.isEmpty || !meds.isEmpty {
            let medNames = Set(meds.map { $0.name }).joined(separator: "、")
            medContext = "排程藥品共 \(plans.count) 項，期間內累計登記服藥 \(meds.count) 次（包含：\(medNames.isEmpty ? "無" : medNames)）。"
        }
        
        // 4. 每日量表評估上下文
        var assessmentContext = "未填寫每日量表評估。"
        if !assessments.isEmpty {
            let latest = assessments.sorted(by: { $0.date > $1.date }).first!
            assessmentContext = "期間內共自評 \(assessments.count) 次。最近一次自評總分 \(latest.totalScore) 分（心情認知: \(latest.moodScore)分、日常生活能力: \(latest.adlScore)分、動作能力: \(latest.motorScore)分）。"
        }
        
        // 5. 表徵症狀上下文
        let symptomContext = symptoms.isEmpty ? "無異常表徵登記。" : symptoms.map { "[\(dateFormatter.string(from: $0.date))] \($0.symptomNote)" }.joined(separator: "；")
        
        // 6. 心情留言上下文
        let moodContext = !payload.includeMoodNotes ? "未勾選引用心情留言。" : (moods.isEmpty ? "無心情留言。" : moods.map { "[\(dateFormatter.string(from: $0.date))] \($0.content) (\($0.moodName ?? "日常"))" }.joined(separator: "；"))
        
        // 7. 組裝 OpenAI 提示詞 (強制 JSON 結構化回傳)
        let systemPrompt = """
        你是專為帕金森氏症病患整理「診間看診溝看卡片」的醫療 AI 助理。
        請根據使用者的數據紀錄與所勾選的主題，產出一份給主治醫師快速閱讀的結構化醫病情資。
        
        【撰寫原則】：
        1. 語言精準、客觀、聚焦臨床重點（如 Wearing-off 藥效消退、異動症、凍結步態、睡眠障礙、日常生活功能障礙）。
        2. 請嚴格依照指定的 JSON 格式輸出，不要包含額外的 Markdown 格式或文字。
        3. 欄位說明：
           - preparation_before_visit: 看病前準備事項與隨身資料攜帶提醒。
           - patient_status_description: 動作狀況、量表分數與生活功能受限具體描述。
           - comparison_with_last_visit: 與前期相比的惡化或改善趨勢。
           - other_medications_or_notes: 跨科用藥或特殊作息補充。
           - questions_for_doctor: 列出 2~3 點具體想諮詢專科醫師的用藥與處置問題。
           - custom_fields_summary: 針對使用者自訂項目給予對應的摘要字串陣列。
        """
        
        let customFieldsPrompt = payload.customFields?.map { "自訂欄位名稱：\($0.title)" }.joined(separator: "\n") ?? "無自訂欄位"
        
        let userPrompt = """
        【報告區間】\(dateFormatter.string(from: payload.startDate)) 至 \(dateFormatter.string(from: payload.endDate))
        【使用者勾選的報告大項】\(payload.selectedReportTypes.joined(separator: "、"))
        【使用者勾選深入分析的主題】\(payload.selectedCategories.joined(separator: "、"))
        【其他補充說明】\(payload.customCategoryText ?? "無")
        【使用者自訂欄位】
        \(customFieldsPrompt)
        
        【期間數據庫彙整】：
        - 震顫感測器數據：\(tremorContext)
        - 生理健康指標：\(vitalsContext)
        - 用藥狀況：\(medContext)
        - 每日症狀自評量表：\(assessmentContext)
        - 肢體異常表徵：\(symptomContext)
        - 心情動態：\(moodContext)
        
        請回傳以下結構之 JSON 物件：
        {
          "preparation_before_visit": "...",
          "patient_status_description": "...",
          "comparison_with_last_visit": "...",
          "other_medications_or_notes": "...",
          "questions_for_doctor": "...",
          "custom_fields_summary": [
            { "title": "...", "content": "..." }
          ]
        }
        """
        
        let auth = try getOpenAIHeaders()
        
        struct OpenAIBody: Content {
            let model: String
            let messages: [[String: String]]
            let response_format: [String: String]
        }
        
        let openAIBody = OpenAIBody(
            model: "gpt-4o-mini",
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            response_format: ["type": "json_object"]
        )
        
        let clientResponse = try await req.client.post("https://api.openai.com/v1/chat/completions", headers: auth.headers) { clientReq in
            try clientReq.content.encode(openAIBody, as: .json)
        }
        
        guard clientResponse.status == .ok else {
            throw Abort(.badGateway, reason: "OpenAI 服務連線失敗")
        }
        
        struct OpenAIJSONResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }
                let message: Message
            }
            let choices: [Choice]
        }
        
        let aiResponse = try clientResponse.content.decode(OpenAIJSONResponse.self)
        guard let contentString = aiResponse.choices.first?.message.content,
              let contentData = contentString.data(using: .utf8) else {
            throw Abort(.internalServerError, reason: "解析 AI 回應失敗")
        }
        
        // 🛡️ 容錯解析結構體 (相容 String 與 [String] 陣列，並符合 any Decoder 語法)
        struct OpenAIResult: Decodable {
            let preparation_before_visit: String?
            let patient_status_description: String?
            let comparison_with_last_visit: String?
            let other_medications_or_notes: String?
            let questions_for_doctor: String?
            let custom_fields_summary: [CustomReportFieldDTO]?
            
            enum CodingKeys: String, CodingKey {
                case preparation_before_visit
                case patient_status_description
                case comparison_with_last_visit
                case other_medications_or_notes
                case questions_for_doctor
                case custom_fields_summary
            }
            
            private static func decodeStringOrArray(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
                if let str = try? container.decode(String.self, forKey: key) {
                    return str
                }
                if let arr = try? container.decode([String].self, forKey: key) {
                    return arr.joined(separator: "\n")
                }
                return nil
            }
            
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.preparation_before_visit = Self.decodeStringOrArray(from: container, forKey: .preparation_before_visit)
                self.patient_status_description = Self.decodeStringOrArray(from: container, forKey: .patient_status_description)
                self.comparison_with_last_visit = Self.decodeStringOrArray(from: container, forKey: .comparison_with_last_visit)
                self.other_medications_or_notes = Self.decodeStringOrArray(from: container, forKey: .other_medications_or_notes)
                self.questions_for_doctor = Self.decodeStringOrArray(from: container, forKey: .questions_for_doctor)
                self.custom_fields_summary = try? container.decode([CustomReportFieldDTO].self, forKey: .custom_fields_summary)
            }
        }
        
        let result = try JSONDecoder().decode(OpenAIResult.self, from: contentData)
        
        let finalResponse = ConsultationSummaryResponseDTO(
            preparationBeforeVisit: result.preparation_before_visit ?? "",
            patientStatusDescription: result.patient_status_description ?? "",
            comparisonWithLastVisit: result.comparison_with_last_visit ?? "",
            otherMedicationsOrNotes: result.other_medications_or_notes ?? "",
            questionsForDoctor: result.questions_for_doctor ?? "",
            customFieldsSummary: result.custom_fields_summary ?? []
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(finalResponse)
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: body))
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
        let auth = try getOpenAIHeaders()
        let url = "https://api.openai.com/v1/embeddings"
        let requestBody = OpenAIEmbeddingRequest(input: text)
        
        let response = try await req.client.post(URI(string: url), headers: auth.headers) { clientReq in
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
    
    // MARK: - API: 取得歷史對話紀錄 (GET /api/ai/history)
    @Sendable
    func getChatHistory(req: Request) async throws -> Response { // 🔥 改為回傳 Response
        let user = try req.auth.require(UserPayload.self)
        let userID = String(user.userID)
        
        let history = try await ChatHistory.query(on: req.db)
            .filter(\.$userID == userID)
            .sort(\.$createdAt, .ascending)
            .all()
        
        let dtos = history.map { chat in
            ChatHistoryResponseDTO(
                id: chat.id,
                role: chat.role,
                content: chat.content,
                createdAt: chat.createdAt
            )
        }
        
        // 🔥 強制使用 ISO8601 編碼輸出，保留時分秒並避開全域 yyyy-MM-dd 截斷
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(dtos)
        
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: body)
        )
    }
    // MARK: - 🌟 API: 讀取最新看診前準備 (GET /api/ai/consultation-preparation)
    @Sendable
    func getConsultationPreparation(req: Request) async throws -> Response {
        let user = try req.auth.require(UserPayload.self)
        let targetPatientID = try await getTargetPatientID(req: req, currentUserID: user.userID)
        
        let record = try await ConsultationPreparation.query(on: req.db)
            .filter(\.$userID == targetPatientID)
            .first()
        
        let responseDTO = ConsultationPreparationResponseDTO(
            content: record?.content ?? "",
            updatedAt: record?.updatedAt ?? record?.createdAt
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(responseDTO)
        
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: body)
        )
    }
    
    // MARK: - 🌟 API: 儲存/覆寫看診前準備 (PUT /api/ai/consultation-preparation)
    @Sendable
    func saveConsultationPreparation(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(UserPayload.self)
        let targetPatientID = try await getTargetPatientID(req: req, currentUserID: user.userID)
        let dto = try req.content.decode(UpdateConsultationPreparationRequestDTO.self)
        
        if let existing = try await ConsultationPreparation.query(on: req.db)
            .filter(\.$userID == targetPatientID)
            .first() {
            existing.content = dto.content
            try await existing.update(on: req.db)
        } else {
            let newRecord = ConsultationPreparation(
                userID: targetPatientID,
                content: dto.content
            )
            try await newRecord.save(on: req.db)
        }
        
        return .ok
    }
}
