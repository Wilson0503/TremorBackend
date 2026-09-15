import Fluent
import Vapor

struct DailyController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let daily = routes.grouped("daily")
        daily.post("sync", use: syncRecord)
        daily.get("all", use: getAllRecords)
        daily.delete(":recordID", use: deleteRecord)
    }
    
    // MARK: - 🔒 核心輔助函式：動態獲取當前看板對應之「病患 ID」
    private func getTargetPatientID(req: Request, currentUserID: Int) async throws -> Int {
        if let bond = try await UserBond.query(on: req.db)
            .filter(\.$caregiverID == currentUserID)
            .first() {
            return bond.patientID
        }
        return currentUserID
    }
    
    // MARK: - 1. 同步便利貼 (新增或修改)
    @Sendable
    func syncRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try req.content.decode(DailyRequestDTO.self, using: decoder)
        
        let isCaregiverOnly = data.isCaregiverOnly ?? false
        
        // 檢查資料庫是否已有這張便利貼
        if let existing = try await DailyRecord.find(data.id, on: req.db) {
            // 安全防禦：僅限發布者本人修改
            guard existing.userID == payload.userID || (existing.isCaregiverOnly && payload.userID != existing.userID) else {
                throw Abort(.forbidden, reason: "您無權修改此便利貼")
            }
            existing.content = data.content
            existing.date = data.date
            existing.colorHex = data.colorHex
            existing.sender = data.sender
            existing.moodName = data.moodName
            existing.isCaregiverOnly = isCaregiverOnly
            try await existing.update(on: req.db)
        } else {
            // 🔥 核心修正：user_id 儲存真實發布者 ID (payload.userID)，不再強制寫入病患 ID
            let newRecord = DailyRecord(
                id: data.id,
                userID: payload.userID, // 👈 照護者發布即為照護者 ID，病患發布即為病患 ID
                content: data.content,
                date: data.date,
                colorHex: data.colorHex,
                sender: data.sender,
                moodName: data.moodName,
                isCaregiverOnly: isCaregiverOnly
            )
            try await newRecord.create(on: req.db)
        }
        return .ok
    }
    
    // MARK: - 2. 獲取當前看板的所有便利貼
    @Sendable
    func getAllRecords(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)
        let targetPatientID = try await getTargetPatientID(req: req, currentUserID: payload.userID)
        
        guard let currentUser = try await User.find(payload.userID, on: req.db) else {
            throw Abort(.unauthorized)
        }
        
        // 1. 取得該看板的所有成員（病患本人 + 所有連動的照護者）
        let bonds = try await UserBond.query(on: req.db)
            .filter(\.$patientID == targetPatientID)
            .all()
        let caregiverIDs = bonds.map { $0.caregiverID }
        let boardMemberIDs = Array(Set([targetPatientID] + caregiverIDs))
        
        // 2. 查詢該看板下所有成員發布的便利貼
        let query = DailyRecord.query(on: req.db)
            .filter(\.$userID ~~ boardMemberIDs)
        
        // 🔥 隱私隔離：病患端 (role == 0) 嚴格隱藏「僅照護者可查看」的留言
        if currentUser.role == 0 {
            query.filter(\.$isCaregiverOnly == false)
        }
        
        let records = try await query.sort(\.$date, .descending).all()
        
        // 3. 快取所有成員資料，動態反射最新姓名
        let boardUsers = try await User.query(on: req.db)
            .filter(\.$id ~~ boardMemberIDs)
            .all()
        let userMap = Dictionary(uniqueKeysWithValues: boardUsers.compactMap { user in
            user.id.map { ($0, user) }
        })
        
        // 4. 組裝 Response DTO
        let responseDTOs = records.map { record -> DailyResponseDTO in
            let displayName: String
            if record.sender == "小安助理代記" || record.sender.contains("小安") {
                displayName = record.sender
            } else if let author = userMap[record.userID], let name = author.name, !name.isEmpty {
                displayName = name
            } else {
                displayName = record.sender
            }
            
            return DailyResponseDTO(
                id: record.id ?? "",
                userID: record.userID, // 👈 回傳真實作者 ID，App 才能精確判定刪除按鈕顯示
                content: record.content,
                date: record.date,
                colorHex: record.colorHex,
                sender: displayName,
                moodName: record.moodName,
                isCaregiverOnly: record.isCaregiverOnly
            )
        }
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(responseDTOs)
        
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
        
        guard let record = try await DailyRecord.find(recordID, on: req.db) else {
            throw Abort(.notFound, reason: "找不到該筆紀錄")
        }
        
        guard let currentUser = try await User.find(payload.userID, on: req.db) else {
            throw Abort(.unauthorized)
        }
        
        // 權限檢查：只能刪除自己發布的留言（每位使用者僅能編輯或刪除自己發布的留言）
        // 🛡️ 防呆相容舊資料：若為舊版遺留之照護者專屬留言且當前為照護者，亦允許刪除
        let isAuthor = (record.userID == payload.userID)
        let isCaregiverCleaningOldRecord = (record.isCaregiverOnly && currentUser.role == 1)
        
        guard isAuthor || isCaregiverCleaningOldRecord else {
            throw Abort(.forbidden, reason: "您無權刪除其他使用者發布的便利貼")
        }
        
        try await record.delete(on: req.db)
        return .noContent
    }
}
