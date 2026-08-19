import Fluent
import Vapor
import JWT
import Foundation

struct TremorController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let tremor = routes.grouped("tremor")
        
        // 🚀 關鍵修改：將 raw 原始數據接收閘門放寬到 50MB
        tremor.on(.POST, "raw", body: .collect(maxSize: "50mb"), use: uploadRawData)
        
        // 其他維持不變
        tremor.post("analysis", use: uploadAnalysisRecord)
        tremor.get("history", use: getAnalysisHistory)
        tremor.get("weekly-report", use: getWeeklyReport)
    }
    
    // MARK: - 1. 接收原始 IMU 數據 (批次寫入)
    @Sendable
    func uploadRawData(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let data = try req.content.decode(RawTremorUploadRequest.self)
        
        // 為了效能，將陣列轉換為 Model 後一次性批次存入資料庫
        let records = data.points.map { point in
            RawTremorData(
                userID: payload.userID,
                sessionId: data.sessionId,
                sequence: point.sequence,
                sampleTickMs: point.sampleTickMs,
                gyroXDps: point.gyroXDps,
                gyroYDps: point.gyroYDps,
                gyroZDps: point.gyroZDps,
                sensorValid: point.sensorValid,
                motorEnabled: point.motorEnabled
            )
        }
        
        try await records.create(on: req.db)
        return .ok
    }
    
    // MARK: - 2. 接收演算法分析結果 (單筆寫入)
    @Sendable
    func uploadAnalysisRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let data = try req.content.decode(TremorAnalysisUploadRequest.self)
        
        // 將前端的 Int64 毫秒時間戳轉換為 Vapor 的 Date
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
    
    // MARK: - 3. 取得歷史分析紀錄
    @Sendable
    func getAnalysisHistory(req: Request) async throws -> [TremorAnalysisRecord] {
        let payload = try req.auth.require(UserPayload.self)
        
        return try await TremorAnalysisRecord.query(on: req.db)
            .filter(\.$userID == payload.userID)
            .sort(\.$recordedAt, .descending)
            .all()
    }
    
    // MARK: - 4. 產生動態週報 (給 App 畫圖用)
    @Sendable
    func getWeeklyReport(req: Request) async throws -> [TrendPoint] {
        let payload = try req.auth.require(UserPayload.self)
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        
        // 改從「分析資料表」抓取，且只抓取資料有效的數據
        let records = try await TremorAnalysisRecord.query(on: req.db)
            .filter(\.$userID == payload.userID)
            .filter(\.$recordedAt >= sevenDaysAgo)
            .filter(\.$dataValid == true) // 排除無效雜訊
            .sort(\.$recordedAt, .ascending)
            .all()
        
        let calendar = Calendar.current
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
