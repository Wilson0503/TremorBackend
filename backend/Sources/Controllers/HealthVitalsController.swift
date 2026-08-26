import Fluent
import Vapor
import Foundation

struct HealthVitalsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let vitals = routes.grouped("vitals")
        
        vitals.post("add", use: addRecord)
        vitals.get("search", use: getRecordsByDate)
        vitals.put(":recordID", use: updateRecord)
        vitals.delete(":recordID", use: deleteRecord)
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

    // MARK: - 1. 新增生理數據紀錄
    @Sendable
    func addRecord(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try req.content.decode(CreateHealthVitalsRequestDTO.self, using: decoder)

        let record = HealthVitalsRecord(
            userID: targetUserID,
            date: data.date,
            systolicBP: data.systolicBP,
            diastolicBP: data.diastolicBP,
            bloodSugar: data.bloodSugar,
            bodyTemp: data.bodyTemp,
            bodyWeight: data.bodyWeight,
            sleepHours: data.sleepHours,
            foodAmount: data.foodAmount
        )

        try await record.save(on: req.db)
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(record.toDTO())
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: body))
    }

    // MARK: - 2. 查詢生理數據紀錄
    @Sendable
    func getRecordsByDate(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)

        let searchDateString = req.query[String.self, at: "date"]
        let records: [HealthVitalsRecord]

        if searchDateString == nil || searchDateString?.isEmpty == true {
            records = try await HealthVitalsRecord.query(on: req.db)
                .filter(\.$userID == targetUserID)
                .sort(\.$date, .descending)
                .all()
        } else {
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: "Asia/Taipei") ?? TimeZone(secondsFromGMT: 8 * 3600)!
            formatter.dateFormat = "yyyy-MM-dd"

            guard let dateString = searchDateString, let dayStart = formatter.date(from: dateString) else {
                throw Abort(.badRequest, reason: "日期格式錯誤，請使用 yyyy-MM-dd")
            }
            let dayEnd = dayStart.addingTimeInterval(24 * 3600)

            records = try await HealthVitalsRecord.query(on: req.db)
                .filter(\.$userID == targetUserID)
                .filter(\.$date >= dayStart)
                .filter(\.$date < dayEnd)
                .sort(\.$date, .descending)
                .all()
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(records.map { $0.toDTO() })
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: body))
    }

    // MARK: - 3. 編輯生理數據紀錄
    @Sendable
    func updateRecord(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)

        guard let recordID = req.parameters.get("recordID", as: Int.self) else {
            throw Abort(.badRequest, reason: "無效的紀錄 ID")
        }

        guard let record = try await HealthVitalsRecord.query(on: req.db)
            .filter(\.$id == recordID)
            .filter(\.$userID == targetUserID)
            .first() else {
            throw Abort(.notFound, reason: "找不到該筆生理數據紀錄或無權限修改")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try req.content.decode(UpdateHealthVitalsRequestDTO.self, using: decoder)

        if let date = data.date { record.date = date }
        if let sBP = data.systolicBP { record.systolicBP = sBP }
        if let dBP = data.diastolicBP { record.diastolicBP = dBP }
        if let sugar = data.bloodSugar { record.bloodSugar = sugar }
        if let temp = data.bodyTemp { record.bodyTemp = temp }
        if let weight = data.bodyWeight { record.bodyWeight = weight }
        if let sleep = data.sleepHours { record.sleepHours = sleep }
        if let food = data.foodAmount { record.foodAmount = food }

        try await record.update(on: req.db)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(record.toDTO())
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: body))
    }

    // MARK: - 4. 刪除生理數據紀錄
    @Sendable
    func deleteRecord(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)

        guard let recordID = req.parameters.get("recordID", as: Int.self) else {
            throw Abort(.badRequest, reason: "無效的紀錄 ID")
        }

        guard let record = try await HealthVitalsRecord.query(on: req.db)
            .filter(\.$id == recordID)
            .filter(\.$userID == targetUserID)
            .first() else {
            throw Abort(.notFound, reason: "找不到該筆紀錄或無權限刪除")
        }

        try await record.delete(on: req.db)
        return .noContent
    }
}
