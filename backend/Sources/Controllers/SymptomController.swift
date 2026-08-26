import Fluent
import Vapor
import Foundation

struct SymptomController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let symptoms = routes.grouped("symptom")
        
        // 🚀 關鍵修改：因為有影片與圖片，將 body 接收大小放寬到 50MB (可依需求調整)
        symptoms.on(.POST, "add", body: .collect(maxSize: "50mb"), use: addRecord)
        
        symptoms.get("search", use: getRecordsByDate)
        symptoms.delete(":recordID", use: deleteRecord)
        symptoms.on(.PUT, ":recordID", body: .collect(maxSize: "50mb"), use: updateRecord)
    }
    
    // MARK: - 🔒 核心輔助函式：動態判斷要操作哪位病患的資料
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
    
    // 1. 儲存表徵紀錄
    @Sendable
    func addRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        struct AddSymptomRequest: Content {
            let date: Date
            let symptomNote: String
            let mediaDataList: [Data]
            let isVideo: Bool
        }
        
        let data = try req.content.decode(AddSymptomRequest.self, using: decoder)
        
        let record = SymptomRecord(
            userID: targetUserID,
            date: data.date,
            symptomNote: data.symptomNote,
            mediaDataList: data.mediaDataList,
            isVideo: data.isVideo
        )
        
        try await record.save(on: req.db)
        return .ok
    }
    
    // 2. 查詢表徵紀錄（支援單日查詢或全部查詢）
    @Sendable
    func getRecordsByDate(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
        
        let searchDateString = req.query[String.self, at: "date"]
        let records: [SymptomRecord]
        
        if searchDateString == nil || searchDateString?.isEmpty == true {
            records = try await SymptomRecord.query(on: req.db)
                .filter(\.$userID == targetUserID)
                .sort(\.$date, .descending) // 預設由新到舊
                .all()
        } else {
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: "Asia/Taipei") ?? TimeZone(secondsFromGMT: 8 * 3600)!
            formatter.dateFormat = "yyyy-MM-dd"
            
            guard let dateString = searchDateString, let dayStart = formatter.date(from: dateString) else {
                throw Abort(.badRequest, reason: "日期格式錯誤，請使用 yyyy-MM-dd")
            }
            let dayEnd = dayStart.addingTimeInterval(24 * 3600)
            
            records = try await SymptomRecord.query(on: req.db)
                .filter(\.$userID == targetUserID)
                .filter(\.$date >= dayStart)
                .filter(\.$date < dayEnd)
                .sort(\.$date, .descending)
                .all()
        }
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(records)
        
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: body)
        )
    }
    
    // 3. 刪除表徵紀錄
    @Sendable
    func deleteRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
        
        guard let recordID = req.parameters.get("recordID", as: Int.self) else {
            throw Abort(.badRequest, reason: "無效的紀錄 ID")
        }
        
        guard let record = try await SymptomRecord.query(on: req.db)
            .filter(\.$id == recordID)
            .filter(\.$userID == targetUserID)
            .first() else {
            throw Abort(.notFound, reason: "找不到該筆紀錄或無權限刪除")
        }
        
        try await record.delete(on: req.db)
        return .noContent
    }
    // MARK: - 🌟 4. 編輯表徵紀錄
    @Sendable
    func updateRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
        
        guard let recordID = req.parameters.get("recordID", as: Int.self) else {
            throw Abort(.badRequest, reason: "無效的紀錄 ID")
        }
        
        guard let record = try await SymptomRecord.query(on: req.db)
            .filter(\.$id == recordID)
            .filter(\.$userID == targetUserID)
            .first() else {
            throw Abort(.notFound, reason: "找不到該筆表徵紀錄或無權限修改")
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        struct UpdateSymptomRequest: Content {
            let date: Date?
            let symptomNote: String?
            let mediaDataList: [Data]?
            let isVideo: Bool?
        }
        
        let data = try req.content.decode(UpdateSymptomRequest.self, using: decoder)
        
        if let date = data.date { record.date = date }
        if let note = data.symptomNote { record.symptomNote = note }
        if let media = data.mediaDataList { record.mediaDataList = media }
        if let isVideo = data.isVideo { record.isVideo = isVideo }
        
        try await record.update(on: req.db)
        return .ok
    }
}
