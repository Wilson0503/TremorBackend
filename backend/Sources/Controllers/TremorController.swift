import Fluent
import Vapor
import JWT
import Foundation

struct TremorController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let tremor = routes.grouped("tremor")
        
        tremor.post("raw", use: uploadRawData)
        tremor.get("raw", use: getRawDataHistory) // 👈 新增：讀取所有 Raw Data 紀錄
        tremor.post("analysis", use: uploadAnalysisRecord)
        tremor.get("history", use: getAnalysisHistory)
        tremor.get("weekly-report", use: getWeeklyReport)
    }
    
    // MARK: - 1. 接收原始 IMU 數據 (單筆 400 點壓縮寫入)
    @Sendable
    func uploadRawData(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let data = try req.content.decode(RawTremorUploadRequest.self)
        
        let record = RawTremorData(
            userID: payload.userID,
            sessionId: data.sessionId,
            sampleCount: data.sampleCount,
            compressedData: data.compressedData
        )
        
        try await record.save(on: req.db)
        return .ok
    }
    
    // MARK: - 1-1. 讀取該使用者的所有原始 IMU 壓縮紀錄 (可依需求指定 sessionId)
    @Sendable
    func getRawDataHistory(req: Request) async throws -> [RawTremorData] {
        let payload = try req.auth.require(UserPayload.self)
        
        return try await RawTremorData.query(on: req.db)
            .filter(\.$userID == payload.userID)
            .sort(\.$createdAt, .descending)
            .all()
    }
    
    // MARK: - 2. 接收演算法分析結果 (單筆寫入)
    @Sendable
    func uploadAnalysisRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let data = try req.content.decode(TremorAnalysisUploadRequest.self)
        
        let date = Date(timeIntervalSince1970: Double(data.recordedAtUtcMs) / 1000.0)
        
        let record = TremorAnalysisRecord(
            id: data.id,
            userID: payload.userID,
            sessionId: data.sessionId,
            recordedAt: date,
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
    
    // MARK: - 🔒 核心輔助函式：動態判斷目標病患 ID (支援照護者代看)
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
    
    // MARK: - 3. 取得歷史分析紀錄 (GET /tremor/history)
    @Sendable
    func getAnalysisHistory(req: Request) async throws -> Response { // 🔥 改為回傳 Response
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
        
        let records = try await TremorAnalysisRecord.query(on: req.db)
            .filter(\.$userID == targetUserID)
            .sort(\.$recordedAt, .descending)
            .all()
        
        // 🔥 強制使用 ISO8601 編碼輸出，保留 recordedAt 的完整時分秒
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(records)
        
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: body)
        )
    }
    
    // MARK: - 4. 產生動態週報 (給 App 畫圖用)
    @Sendable
    func getWeeklyReport(req: Request) async throws -> [TrendPoint] {
        let payload = try req.auth.require(UserPayload.self)
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        
        let records = try await TremorAnalysisRecord.query(on: req.db)
            .filter(\.$userID == payload.userID)
            .filter(\.$recordedAt >= sevenDaysAgo)
            .filter(\.$dataValid == true)
            .sort(\.$recordedAt, .ascending)
            .all()
        
        // 🌟 修正：設定 Calendar 時區為台灣時間
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
}
