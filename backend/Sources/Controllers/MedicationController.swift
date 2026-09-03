import Fluent
import Vapor

struct MedicationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let meds = routes.grouped("medication")
        
        // 接收貼布照片，放寬 body 大小至 50MB
        meds.on(.POST, "add", body: .collect(maxSize: "50mb"), use: addRecord)
        meds.get("search", use: getRecordsByDate)
        meds.delete(":recordID", use: deleteRecord)
        meds.on(.PUT, ":recordID", body: .collect(maxSize: "50mb"), use: updateRecord)
    }
    
    // 💡 封裝目標病患 ID 與當前操作者角色
    private struct TargetContext {
        let patientID: Int      // 資料歸屬病患 ID
        let operatorRole: Int   // 操作者身分 (0: 病患本人, 1: 照護者)
    }
    
    // MARK: - 🔒 核心輔助函式：解析目標情境與校驗授權
    private func resolveTargetContext(req: Request, currentUserID: Int, requireAddPermission: Bool = false) async throws -> TargetContext {
        guard let currentUser = try await User.find(currentUserID, on: req.db) else {
            throw Abort(.notFound, reason: "找不到您的帳號")
        }
        
        if currentUser.role == 1 {
            guard let bond = try await UserBond.query(on: req.db)
                .filter(\.$caregiverID == currentUserID)
                .first() else {
                throw Abort(.notFound, reason: "目前尚未綁定任何被照護者")
            }
            
            // 🛡️ 照護者代為新增或異動時，校驗 canAddMedRecord
            if requireAddPermission && !bond.canAddMedRecord {
                throw Abort(.forbidden, reason: "被照護者尚未授權您新增或編輯用藥紀錄")
            }
            
            return TargetContext(patientID: bond.patientID, operatorRole: currentUser.role)
        }
        
        return TargetContext(patientID: currentUserID, operatorRole: currentUser.role)
    }
    
    // MARK: - 1. 儲存用藥紀錄 (POST /medication/add)
    @Sendable
    func addRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        // 🔥 解析出病患 ID 與操作者身分，並核對 canAddMedRecord
        let context = try await resolveTargetContext(req: req, currentUserID: payload.userID, requireAddPermission: true)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        struct AddMedRequest: Content {
            let date: Date
            let name: String
            let dose: String
            let medType: String
            let patchRegion: String?
            let skinCondition: String?
            let skinImageDataList: [Data]?
        }
        
        let data = try req.content.decode(AddMedRequest.self, using: decoder)
        
        // 🔒 自動代入 context.patientID 與 context.operatorRole，不依賴前端傳值
        let record = MedicationRecord(
            userID: context.patientID,
            date: data.date,
            name: data.name,
            dose: data.dose,
            medType: data.medType,
            patchRegion: data.patchRegion,
            skinCondition: data.skinCondition,
            skinImageDataList: data.skinImageDataList ?? [],
            creatorRole: context.operatorRole // 🔥 自動標記 0 或 1
        )
        
        try await record.save(on: req.db)
        return .ok
    }
    
    // MARK: - 2. 查詢用藥紀錄 (GET /medication/search)
    @Sendable
    func getRecordsByDate(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)
        // 🔍 純讀取紀錄不阻擋，讓照護者能即時檢視
        let context = try await resolveTargetContext(req: req, currentUserID: payload.userID, requireAddPermission: false)
        
        let searchDateString = req.query[String.self, at: "date"]
        let records: [MedicationRecord]
        
        if searchDateString == nil || searchDateString?.isEmpty == true {
            records = try await MedicationRecord.query(on: req.db)
                .filter(\.$userID == context.patientID)
                .sort(\.$date, .ascending)
                .all()
        } else {
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: "Asia/Taipei") ?? TimeZone(secondsFromGMT: 8 * 3600)!
            formatter.dateFormat = "yyyy-MM-dd"
            guard let dateString = searchDateString, let dayStart = formatter.date(from: dateString) else {
                throw Abort(.badRequest, reason: "日期格式錯誤，請使用 yyyy-MM-dd")
            }
            let dayEnd = dayStart.addingTimeInterval(24 * 3600)
            
            records = try await MedicationRecord.query(on: req.db)
                .filter(\.$userID == context.patientID)
                .filter(\.$date >= dayStart)
                .filter(\.$date < dayEnd)
                .sort(\.$date, .ascending)
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
    
    // MARK: - 3. 刪除用藥紀錄 (DELETE /medication/:recordID)
    @Sendable
    func deleteRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let context = try await resolveTargetContext(req: req, currentUserID: payload.userID, requireAddPermission: true)
        
        guard let recordID = req.parameters.get("recordID", as: Int.self) else {
            throw Abort(.badRequest, reason: "無效的紀錄 ID")
        }
        
        guard let record = try await MedicationRecord.query(on: req.db)
            .filter(\.$id == recordID)
            .filter(\.$userID == context.patientID)
            .first() else {
            throw Abort(.notFound, reason: "找不到該筆紀錄或無權限刪除")
        }
        
        try await record.delete(on: req.db)
        return .noContent
    }
    
    // MARK: - 4. 編輯用藥紀錄 (PUT /medication/:recordID)
    @Sendable
    func updateRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let context = try await resolveTargetContext(req: req, currentUserID: payload.userID, requireAddPermission: true)
        
        guard let recordID = req.parameters.get("recordID", as: Int.self) else {
            throw Abort(.badRequest, reason: "無效的紀錄 ID")
        }
        
        guard let record = try await MedicationRecord.query(on: req.db)
            .filter(\.$id == recordID)
            .filter(\.$userID == context.patientID)
            .first() else {
            throw Abort(.notFound, reason: "找不到該筆用藥紀錄或無權限修改")
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        struct UpdateMedRequest: Content {
            let date: Date?
            let name: String?
            let dose: String?
            let medType: String?
            let patchRegion: String?
            let skinCondition: String?
            let skinImageDataList: [Data]?
        }
        
        let data = try req.content.decode(UpdateMedRequest.self, using: decoder)
        
        if let date = data.date { record.date = date }
        if let name = data.name { record.name = name }
        if let dose = data.dose { record.dose = dose }
        if let medType = data.medType { record.medType = medType }
        if let patchRegion = data.patchRegion { record.patchRegion = patchRegion }
        if let skinCondition = data.skinCondition { record.skinCondition = skinCondition }
        if let images = data.skinImageDataList { record.skinImageDataList = images }
        
        try await record.update(on: req.db)
        return .ok
    }
}
