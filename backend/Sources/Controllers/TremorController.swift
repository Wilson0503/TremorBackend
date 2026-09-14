import Fluent
import Vapor
import JWT
import Foundation

struct TremorController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let tremor = routes.grouped("tremor")
        
        tremor.post("raw", use: uploadRawData)
        tremor.get("raw", use: getRawDataHistory)
        tremor.post("analysis", use: uploadAnalysisRecord)
        tremor.patch("analysis", ":recordID", use: updateAnalysisRecord) // 🔥 精確對應 PATCH /tremor/analysis/:recordId
        tremor.get("history", use: getAnalysisHistory)
        tremor.get("weekly-report", use: getWeeklyReport)
    }
    
    // MARK: - 🔒 核心輔助函式：動態判斷目標病患 ID (僅供查詢代看)
    private func getTargetUserID(req: Request, currentUserID: Int) async throws -> Int {
        guard let currentUser = try await User.find(currentUserID, on: req.db) else {
            throw Abort(.notFound, reason: "找不到您的帳號")
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
    
    // MARK: - 1. 接收原始 IMU 數據 (POST /tremor/raw，僅限病患本人手套上傳)
    @Sendable
    func uploadRawData(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let data = try req.content.decode(RawTremorUploadRequest.self)
        
        let record = RawTremorData(
            userID: payload.userID, // 🔒 嚴格由穿戴手套者本人 ID 寫入
            sessionId: data.sessionId,
            sampleCount: data.sampleCount,
            compressedData: data.compressedData
        )
        
        try await record.save(on: req.db)
        return .ok
    }
    
    // MARK: - 1-1. 讀取原始 IMU 壓縮紀錄 (GET /tremor/raw，支援照護者代看 + ISO 8601)
    @Sendable
    func getRawDataHistory(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID) // 🔍 照護者代看病患
        
        let records = try await RawTremorData.query(on: req.db)
            .filter(\.$userID == targetUserID)
            .sort(\.$createdAt, .descending)
            .all()
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(records)
        
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: body)
        )
    }
    
    // MARK: - 2. 接收演算法分析結果 (POST /tremor/analysis)
    @Sendable
    func uploadAnalysisRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        
        // 🚀 使用獨立 ISO 8601 解碼器，避免時分秒被全域 yyyy-MM-dd 截斷
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try req.content.decode(TremorAnalysisUploadRequest.self, using: decoder)
        
        let record = TremorAnalysisRecord(
            id: data.id,
            userID: payload.userID,
            sessionId: data.sessionId,
            recordedAt: data.recordedAt, // 🔥 直接寫入解碼後的 Date
            dominantFrequencyHz: data.dominantFrequencyHz,
            tremorStrengthRmsDps: data.tremorStrengthRmsDps,
            motorOnFraction: data.motorOnFraction,
            dataValid: data.dataValid,
            frequencyReliable: data.frequencyReliable,
            activityTag: data.activityTag,
            note: data.note
        )
        
        try await record.save(on: req.db)
        return .ok
    }
    
    // MARK: - 3. 取得歷史分析紀錄 (GET /tremor/history，支援照護者代看 + ISO 8601)
    @Sendable
    func getAnalysisHistory(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID) // 🔍 照護者代看病患
        
        let records = try await TremorAnalysisRecord.query(on: req.db)
            .filter(\.$userID == targetUserID)
            .sort(\.$recordedAt, .descending)
            .all()
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(records)
        
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: body)
        )
    }
    
    // MARK: - 4. 產生動態週報 (GET /tremor/weekly-report，支援照護者代看)
    @Sendable
    func getWeeklyReport(req: Request) async throws -> [TrendPoint] {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID) // 🔍 照護者代看病患
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        
        let records = try await TremorAnalysisRecord.query(on: req.db)
            .filter(\.$userID == targetUserID)
            .filter(\.$recordedAt >= sevenDaysAgo)
            .filter(\.$dataValid == true)
            .sort(\.$recordedAt, .ascending)
            .all()
        
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        
        let groupedByDate = Dictionary(grouping: records) { record in
            calendar.startOfDay(for: record.recordedAt)
        }
        
        var report: [TrendPoint] = []
        
        for (date, dayRecords) in groupedByDate {
            let freqs = dayRecords.compactMap { $0.dominantFrequencyHz }
            let amps = dayRecords.compactMap { $0.tremorStrengthRmsDps }
            
            let avgFreq = freqs.isEmpty ? 0 : freqs.reduce(0, +) / Double(freqs.count)
            let avgAmp = amps.isEmpty ? 0 : amps.reduce(0, +) / Double(amps.count)
            
            report.append(TrendPoint(date: date, averageFrequency: avgFreq, averageAmplitude: avgAmp))
        }
        
        return report.sorted { $0.date < $1.date }
    }
    // MARK: - 5. 更新既有震顫分析紀錄 (PATCH /tremor/analysis/:recordID)
    @Sendable
    func updateAnalysisRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        
        // 1. 取得並驗證 URL 上的 recordId
        guard let recordID = req.parameters.get("recordID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "無效的紀錄 UUID 格式")
        }
        
        // 2. 查找紀錄：同時核驗 id 與所屬的 user_id
        guard let record = try await TremorAnalysisRecord.query(on: req.db)
            .filter(\.$id == recordID)
            .filter(\.$userID == payload.userID)
            .first() else {
            throw Abort(.notFound, reason: "找不到該筆分析紀錄或無權限修改")
        }
        
        // 3. 解碼 Request Body
        let data = try req.content.decode(UpdateTremorAnalysisRequestDTO.self)
        
        // 4. 僅更新 activity_tag 與 note，其餘感測數據與時間戳記完全保留
        if let activityTag = data.activityTag {
            record.activityTag = activityTag
        }
        if let note = data.note {
            record.note = note
        }
        
        try await record.update(on: req.db)
        return .ok
    }
}
