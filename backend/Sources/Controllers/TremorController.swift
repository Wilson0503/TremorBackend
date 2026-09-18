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
        tremor.patch("analysis", ":recordID", use: updateAnalysisRecord)
        tremor.get("history", use: getAnalysisHistory)
        tremor.get("weekly-report", use: getWeeklyReport)

        // 🔥 補回：每 0.5 秒即時分析點（批次上傳與區間查詢）
        tremor.post("trend", "batch", use: uploadTrendBatch)
        tremor.get("trend", use: getTrendHistory)
    }
    
    // MARK: - 🛠️ 輔助函式：ISO 8601 編解碼器
    private func iso8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func iso8601Encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func parseISO8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
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
            userID: payload.userID,
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
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
        
        let records = try await RawTremorData.query(on: req.db)
            .filter(\.$userID == targetUserID)
            .sort(\.$createdAt, .descending)
            .all()
        
        let body = try iso8601Encoder().encode(records)
        
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
        let data = try req.content.decode(TremorAnalysisUploadRequest.self, using: iso8601Decoder())
        
        let record = TremorAnalysisRecord(
            id: data.id,
            userID: payload.userID,
            sessionId: data.sessionId,
            recordedAt: data.recordedAt,
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
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
        
        let records = try await TremorAnalysisRecord.query(on: req.db)
            .filter(\.$userID == targetUserID)
            .sort(\.$recordedAt, .descending)
            .all()
        
        let body = try iso8601Encoder().encode(records)
        
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: body)
        )
    }

    // MARK: - 3-1. RMS Trend 批次寫入 (POST /tremor/trend/batch，高效 Bulk 版)
    @Sendable
    func uploadTrendBatch(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let request = try req.content.decode(
            TremorTrendBatchUploadRequest.self,
            using: iso8601Decoder()
        )

        guard !request.points.isEmpty else {
            return .ok
        }

        // 1. 批次查出已存在的 ID，避免重複主鍵
        let incomingIDs = request.points.map(\.id)
        let existingRecords = try await TremorTrendPoint.query(on: req.db)
            .filter(\.$id ~~ incomingIDs)
            .all()
        let existingIDSet = Set(existingRecords.compactMap(\.id))

        // 2. 過濾新資料
        let newRecords = request.points
            .filter { !existingIDSet.contains($0.id) }
            .map { point in
                TremorTrendPoint(
                    id: point.id,
                    userID: payload.userID,
                    sessionId: point.sessionId,
                    recordedAt: point.recordedAt,
                    rmsValue: point.rmsValue,
                    dominantFrequencyHz: point.dominantFrequencyHz,
                    motorOnFraction: point.motorOnFraction,
                    dataValid: point.dataValid,
                    frequencyReliable: point.frequencyReliable
                )
            }

        // 3. 一次性大量寫入
        if !newRecords.isEmpty {
            try await newRecords.create(on: req.db)
        }

        return .ok
    }

    // MARK: - 3-2. RMS Trend 依區間查詢 (GET /tremor/trend?from=...&to=...)
    @Sendable
    func getTrendHistory(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(
            req: req,
            currentUserID: payload.userID
        )

        guard let fromText = req.query[String.self, at: "from"],
              let toText = req.query[String.self, at: "to"],
              let from = parseISO8601(fromText),
              let to = parseISO8601(toText),
              to > from else {
            throw Abort(
                .badRequest,
                reason: "from 與 to 必須是有效 ISO 8601，且 to 必須晚於 from"
            )
        }

        // 單次最多查 48 小時
        guard to.timeIntervalSince(from) <= 48 * 60 * 60 else {
            throw Abort(.badRequest, reason: "單次 Trend 查詢範圍不可超過 48 小時")
        }

        let records = try await TremorTrendPoint.query(on: req.db)
            .filter(\.$userID == targetUserID)
            .filter(\.$recordedAt >= from)
            .filter(\.$recordedAt < to)
            .filter(\.$dataValid == true)
            .sort(\.$recordedAt, .ascending)
            .all()

        let body = try iso8601Encoder().encode(records)

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
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
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
        
        guard let recordID = req.parameters.get("recordID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "無效的紀錄 UUID 格式")
        }
        
        guard let record = try await TremorAnalysisRecord.query(on: req.db)
            .filter(\.$id == recordID)
            .filter(\.$userID == payload.userID)
            .first() else {
            throw Abort(.notFound, reason: "找不到該筆分析紀錄或無權限修改")
        }
        
        let data = try req.content.decode(UpdateTremorAnalysisRequestDTO.self)
        
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
