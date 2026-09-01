import Fluent
import Vapor
import Foundation

struct DailyAssessmentController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let assessment = routes.grouped("assessment")
        assessment.post("submit", use: submitAssessment)
        assessment.get("search", use: getAssessmentByDate)
        assessment.get("history", use: getAssessmentHistory)
        assessment.delete(":recordID", use: deleteAssessment)
    }

    // MARK: - 🔒 核心輔助函式：動態判斷目標病患 ID (支援照護者代辦)
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

    // 1. 提交評估問卷紀錄
    @Sendable
    func submitAssessment(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try req.content.decode(CreateDailyAssessmentRequestDTO.self, using: decoder)

        var detailsJsonString: String? = nil
        if let details = data.details, let encoded = try? JSONEncoder().encode(details) {
            detailsJsonString = String(data: encoded, encoding: .utf8)
        }

        let record = DailyAssessmentRecord(
            userID: targetUserID,
            date: data.date,
            totalScore: data.totalScore,
            moodScore: data.moodScore,
            adlScore: data.adlScore,
            motorScore: data.motorScore,
            detailsJson: detailsJsonString
        )

        try await record.save(on: req.db)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(record)
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: body))
    }

    // 2. 查詢指定單日評估紀錄
    @Sendable
    func getAssessmentByDate(req: Request) async throws -> Response {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)

        let searchDateString = req.query[String.self, at: "date"]
        let records: [DailyAssessmentRecord]

        if searchDateString == nil || searchDateString?.isEmpty == true {
            records = try await DailyAssessmentRecord.query(on: req.db)
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

            records = try await DailyAssessmentRecord.query(on: req.db)
                .filter(\.$userID == targetUserID)
                .filter(\.$date >= dayStart)
                .filter(\.$date < dayEnd)
                .sort(\.$date, .descending)
                .all()
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(records)
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: body))
    }

    // 3. 取得近期評估歷史
    @Sendable
    func getAssessmentHistory(req: Request) async throws -> [DailyAssessmentRecord] {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)

        return try await DailyAssessmentRecord.query(on: req.db)
            .filter(\.$userID == targetUserID)
            .sort(\.$date, .descending)
            .limit(30)
            .all()
    }

    // 4. 刪除評估紀錄
    @Sendable
    func deleteAssessment(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)

        guard let recordID = req.parameters.get("recordID", as: Int.self) else {
            throw Abort(.badRequest, reason: "無效的紀錄 ID")
        }

        guard let record = try await DailyAssessmentRecord.query(on: req.db)
            .filter(\.$id == recordID)
            .filter(\.$userID == targetUserID)
            .first() else {
            throw Abort(.notFound, reason: "找不到該筆評估紀錄或無權限刪除")
        }

        try await record.delete(on: req.db)
        return .noContent
    }
}
