import Fluent
import Vapor
import Foundation

struct MedicationPlanController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let plans = routes.grouped("medication-plan")
        plans.post("save", use: savePlan)      // 新增或修改排程
        plans.get("all", use: getAllPlans)      // 取得所有排程清單
        plans.delete(":planID", use: deletePlan)// 刪除排程
    }
    
    // 🔒 核心輔助函式：動態判斷要操作哪位病患的資料
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
    
    // 1. 新增或更新用藥排程
    @Sendable
    func savePlan(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        // 👇 擴充 DTO 接收 startDate
        struct PlanRequestDTO: Content {
            let id: Int?
            let name: String
            let dose: String
            let medType: String
            let defaultPatchRegion: String?
            let timeSlotsRaw: String
            let startDate: Date // 新增
            let repeatFrequency: String
            let customInterval: Int
            let customUnit: String
            let weekdaysRaw: String
            let monthDaysRaw: String
        }
        
        let data = try req.content.decode(PlanRequestDTO.self, using: decoder)
        
        if let planID = data.id, let existing = try await MedicationPlan.find(planID, on: req.db) {
            guard existing.userID == targetUserID else {
                throw Abort(.forbidden, reason: "您無權修改此排程")
            }
            existing.name = data.name
            existing.dose = data.dose
            existing.medType = data.medType
            existing.defaultPatchRegion = data.defaultPatchRegion
            existing.timeSlotsRaw = data.timeSlotsRaw
            existing.startDate = data.startDate // 👇 補上更新邏輯
            existing.repeatFrequency = data.repeatFrequency
            existing.customInterval = data.customInterval
            existing.customUnit = data.customUnit
            existing.weekdaysRaw = data.weekdaysRaw
            existing.monthDaysRaw = data.monthDaysRaw
            try await existing.update(on: req.db)
        } else {
            let newPlan = MedicationPlan(
                userID: targetUserID,
                name: data.name,
                dose: data.dose,
                medType: data.medType,
                defaultPatchRegion: data.defaultPatchRegion,
                timeSlotsRaw: data.timeSlotsRaw,
                startDate: data.startDate, // 👇 補上新建邏輯
                repeatFrequency: data.repeatFrequency,
                customInterval: data.customInterval,
                customUnit: data.customUnit,
                weekdaysRaw: data.weekdaysRaw,
                monthDaysRaw: data.monthDaysRaw
            )
            try await newPlan.create(on: req.db)
        }
        return .ok
    }
    
    // 2. 取得所有用藥排程清單
    @Sendable
    func getAllPlans(req: Request) async throws -> [MedicationPlan] {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
        
        return try await MedicationPlan.query(on: req.db)
            .filter(\.$userID == targetUserID)
            .sort(\.$createdAt, .descending)
            .all()
    }
    
    // 3. 刪除用藥排程
    @Sendable
    func deletePlan(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let targetUserID = try await getTargetUserID(req: req, currentUserID: payload.userID)
        
        guard let planID = req.parameters.get("planID", as: Int.self) else {
            throw Abort(.badRequest, reason: "無效的排程 ID")
        }
        
        guard let plan = try await MedicationPlan.query(on: req.db)
            .filter(\.$id == planID)
            .filter(\.$userID == targetUserID)
            .first() else {
            throw Abort(.notFound, reason: "找不到該筆排程或無權限刪除")
        }
        
        try await plan.delete(on: req.db)
        return .noContent
    }
}
