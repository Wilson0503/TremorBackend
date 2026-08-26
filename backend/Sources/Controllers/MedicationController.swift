import Fluent
import Vapor

struct MedicationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // 同樣放在受 JWT 保護的群組下
        let meds = routes.grouped("medication")
        
        // 🚀 關鍵修改：因為加入了貼布照片，將 body 接收大小放寬到 50MB (可依需求調整)
        meds.on(.POST, "add", body: .collect(maxSize: "50mb"), use: addRecord)
        
        meds.get("search", use: getRecordsByDate)
        // 接口：DELETE /medication/:recordID
        meds.delete(":recordID", use: deleteRecord)
        meds.on(.PUT, ":recordID", body: .collect(maxSize: "50mb"), use: updateRecord)
    }
    
    // MARK: - 🔒 核心輔助函式：動態判斷要操作哪位病患的資料
    private func getTargetUserID(req: Request, currentUserID: Int) async throws -> Int {
        // 1. 查出當前使用者的實體與身分角色 (role)
        guard let currentUser = try await User.find(currentUserID, on: req.db) else {
            throw Abort(.notFound, reason: "找不到您的帳號")
        }
        
        // 2. 如果是照護者 (role == 1)，則去 UserBond 找綁定的病患
        if currentUser.role == 1 {
            guard let bond = try await UserBond.query(on: req.db)
                .filter(\.$caregiverID == currentUserID)
                .first() else {
                throw Abort(.notFound, reason: "目前尚未綁定任何被照護者")
            }
            return bond.patientID
        }
        
        // 3. 如果是被照護者 (role == 0)，直接回傳自己的 ID
        return currentUserID
    }
    
    // 1. 儲存用藥紀錄 (照護者可代為新增)
    @Sendable
    func addRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        
        // 🔥 動態取得目標 ID
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        // 👇 擴充接收資料的結構
        struct AddMedRequest: Content {
            let date: Date
            let name: String
            let dose: String
            let medType: String
            let patchRegion: String?
            let skinCondition: String?
            let skinImageDataList: [Data]? // 前端可能為空
        }
        
        let data = try req.content.decode(AddMedRequest.self, using: decoder)
        
        // 👇 把新欄位帶入 Model 進行儲存
        let record = MedicationRecord(
            userID: targetUserID,
            date: data.date,
            name: data.name,
            dose: data.dose,
            medType: data.medType,
            patchRegion: data.patchRegion,
            skinCondition: data.skinCondition,
            skinImageDataList: data.skinImageDataList ?? []
        )
        
        try await record.save(on: req.db)
        return .ok
    }
    
    // 2. 查詢用藥紀錄（支援單日查詢或全部查詢）
    @Sendable
    func getRecordsByDate(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)
        
        // 🔥 動態取得目標 ID
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
        
        let searchDateString = req.query[String.self, at: "date"]
        let records: [MedicationRecord]
        
        if searchDateString == nil || searchDateString?.isEmpty == true {
            records = try await MedicationRecord.query(on: req.db)
                .filter(\.$userID == targetUserID) // 🔥 替換為目標病患
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
                .filter(\.$userID == targetUserID) // 🔥 替換為目標病患
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
    
    // 3. 刪除用藥紀錄 (照護者可代為刪除錯置的紀錄)
    @Sendable
    func deleteRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        
        // 🔥 動態取得目標 ID
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
        
        guard let recordID = req.parameters.get("recordID", as: Int.self) else {
            throw Abort(.badRequest, reason: "無效的紀錄 ID")
        }
        
        // 🔥 確保只能刪除目標病患的紀錄
        guard let record = try await MedicationRecord.query(on: req.db)
            .filter(\.$id == recordID)
            .filter(\.$userID == targetUserID) // 🔥 替換為目標病患
            .first() else {
            throw Abort(.notFound, reason: "找不到該筆紀錄或無權限刪除")
        }
        
        try await record.delete(on: req.db)
        
        return .noContent
    }
    // MARK: - 🌟 4. 編輯用藥紀錄
    @Sendable
    func updateRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
        
        guard let recordID = req.parameters.get("recordID", as: Int.self) else {
            throw Abort(.badRequest, reason: "無效的紀錄 ID")
        }
        
        guard let record = try await MedicationRecord.query(on: req.db)
            .filter(\.$id == recordID)
            .filter(\.$userID == targetUserID)
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
