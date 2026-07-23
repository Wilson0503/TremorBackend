import Fluent
import Vapor

struct DailyController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let daily = routes.grouped("daily")
        daily.post("sync", use: syncRecord)
        daily.get("all", use: getAllRecords)
        daily.delete(":recordID", use: deleteRecord)
    }
    
    // MARK: - 🔒 核心輔助函式：動態動態判斷並獲取「目標病患 ID」
    private func getTargetPatientID(req: Request, currentUserID: Int) async throws -> Int {
        // 先去 user_bonds 表查看看目前登入的使用者是不是某個人的「照護者」
        if let bond = try await UserBond.query(on: req.db)
            .filter(\.$caregiverID == currentUserID)
            .first() {
            // 如果是照護者，留言板的對象就是他綁定的被照護者（病患）
            return bond.patientID
        }
        // 如果在綁定表找不到紀錄，代表他本身就是病患，直接返回他自己的 ID
        return currentUserID
    }
    
    // MARK: - 1. 同步便利貼 (新增或修改)
    @Sendable
    func syncRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try req.content.decode(DailyRequestDTO.self, using: decoder)
        
        // 🚀 關鍵修改：動態查出這張便利貼應該歸屬在哪個病患的看板下
        let targetPatientID = try await getTargetPatientID(req: req, currentUserID: payload.userID)
        
        // 檢查資料庫是否已有這張便利貼 (使用前端 SwiftData 的 UUID 字串查詢)
        if let existing = try await DailyRecord.find(data.id, on: req.db) {
            // 安全防禦：確保該便利貼確實屬於目前的病患看板，防止跨帳號竄改
            guard existing.userID == targetPatientID else {
                throw Abort(.forbidden, reason: "您無權修改此便利貼")
            }
            existing.content = data.content
            existing.date = data.date
            existing.colorHex = data.colorHex
            existing.sender = data.sender
            existing.moodName = data.moodName
            try await existing.update(on: req.db)
        } else {
            // 沒有舊紀錄，直接建立新紀錄
            let newRecord = DailyRecord(
                id: data.id,
                userID: targetPatientID, // 👈 核心：不論誰發的，一律存入病患 ID
                content: data.content,
                date: data.date,
                colorHex: data.colorHex,
                sender: data.sender,
                moodName: data.moodName
            )
            try await newRecord.create(on: req.db)
        }
        return .ok
    }
    
    // MARK: - 2. 獲取當前看板的所有便利貼
    @Sendable
    func getAllRecords(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)
        
        // 動態判定要抓哪一個病患的留言板
        let targetPatientID = try await getTargetPatientID(req: req, currentUserID: payload.userID)
        
        // 撈出該病患看板下的所有紀錄，按時間倒序排列（最新留言在最上面）
        let records = try await DailyRecord.query(on: req.db)
            .filter(\.$userID == targetPatientID)
            .sort(\.$date, .descending)
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
    
    // MARK: - 3. 刪除便利貼
    @Sendable
    func deleteRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        
        guard let recordID = req.parameters.get("recordID", as: String.self) else {
            throw Abort(.badRequest, reason: "無效的紀錄 ID")
        }
        
        let targetPatientID = try await getTargetPatientID(req: req, currentUserID: payload.userID)
        
        // 只能刪除目前可見看板下的便利貼
        guard let record = try await DailyRecord.query(on: req.db)
            .filter(\.$id == recordID)
            .filter(\.$userID == targetPatientID)
            .first() else {
            throw Abort(.notFound, reason: "找不到該筆紀錄或無權限刪除")
        }
        
        try await record.delete(on: req.db)
        return .noContent
    }
}
