import Fluent
import Vapor
import JWT

struct TremorController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // 這裡不需要額外加 grouped，因為我們在 routes.swift 已經外包一層 JWT 中介軟體了[cite: 12]
        let tremor = routes.grouped("tremor")
        tremor.post("data", use: uploadData)
        tremor.get("history", use: getHistory) // 移除 URL 中的 :userID，改從 Token 抓
        tremor.get("weekly-report", use: getWeeklyReport)
    }
    
    @Sendable
    func uploadData(req: Request) async throws -> HTTPStatus {
        // 1. 從 Token 中自動解析出 UserPayload[cite: 14]
        let payload = try req.auth.require(UserPayload.self)
        
        let data = try req.content.decode(TremorUploadRequest.self)
        
        // 2. 使用從 Token 拿到的 payload.userID 存檔[cite: 9, 14]
        let record = TremorData(
            userID: payload.userID,
            accX: data.accX,
            accY: data.accY,
            accZ: data.accZ,
            gyroX: data.gyroX,
            gyroY: data.gyroY,
            gyroZ: data.gyroZ
        )
        
        try await record.save(on: req.db)
        return .ok
    }
    
    @Sendable
    func getHistory(req: Request) async throws -> [TremorData] {
        // 1. 同樣從 Token 確保身分[cite: 14]
        let payload = try req.auth.require(UserPayload.self)
        
        // 2. 只搜尋該登入使用者的歷史紀錄[cite: 4, 9]
        return try await TremorData.query(on: req.db)
            .filter(\.$userID == payload.userID)
            .sort(\.$timestamp, .descending)
            .all()
    }
    @Sendable
    func getWeeklyReport(req: Request) async throws -> [TrendPoint] {
        // 1. 從 Token 中自動解析出 UserPayload，確保只抓到該使用者的資料
        let payload = try req.auth.require(UserPayload.self)
        
        // 2. 取得七天前的時間點 (從現在起算 -7 天)
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        
        // 3. 從資料庫抓出該使用者過去七天的所有數據
        // 注意：這裡假設你的 TremorData Model 裡已經有 tremorFrequency 和 amplitude 欄位
        let records = try await TremorData.query(on: req.db)
            .filter(\.$userID == payload.userID)
            .filter(\.$timestamp >= sevenDaysAgo)
            .sort(\.$timestamp, .ascending)
            .all()
        
        // 4. 將數據按「日期」分組並計算平均值
        let calendar = Calendar.current
        let groupedByDate = Dictionary(grouping: records) { record in
            // 將時分秒去掉，只留日期（例如 2026-05-07 00:00:00）
            calendar.startOfDay(for: record.timestamp ?? Date())
        }
        
        var report: [TrendPoint] = []
        
        for (date, dayRecords) in groupedByDate {
            // 計算當天所有紀錄的平均頻率與振幅
            // 如果欄位是可選的(Optional)，使用 compactMap 排除 nil
            let freqs = dayRecords.compactMap { $0.tremorFrequency }
            let amps = dayRecords.compactMap { $0.amplitude }
            
            let avgFreq = freqs.isEmpty ? 0 : freqs.reduce(0, +) / Double(freqs.count)
            let avgAmp = amps.isEmpty ? 0 : amps.reduce(0, +) / Double(amps.count)
            
            report.append(TrendPoint(
                date: date,
                averageFrequency: avgFreq,
                averageAmplitude: avgAmp
            ))
        }
        
        // 按日期排序回傳，方便前端畫折線圖
        return report.sorted { $0.date < $1.date }
    }
}

