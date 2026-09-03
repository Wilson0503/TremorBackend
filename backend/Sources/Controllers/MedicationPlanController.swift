import Fluent
import Vapor
import Foundation

struct MedicationPlanController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let plans = routes.grouped("medication-plan")
        plans.post("save", use: savePlan)
        plans.get("all", use: getAllPlans)
        plans.delete(":planID", use: deletePlan)
    }
    
    // 💡 封裝目標病患 ID 與當前操作者角色
    private struct TargetContext {
        let patientID: Int      // 資料歸屬病患 ID
        let operatorRole: Int   // 操作者身分 (0: 病患本人, 1: 照護者)
    }
    
    // MARK: - 🔒 核心輔助函式：解析目標情境與校驗排程授權
    private func resolveTargetContext(req: Request, currentUserID: Int, requireManagePermission: Bool = false) async throws -> TargetContext {
        guard let currentUser = try await User.find(currentUserID, on: req.db) else {
            throw Abort(.notFound, reason: "找不到您的帳號")
        }
        
        if currentUser.role == 1 {
            guard let bond = try await UserBond.query(on: req.db)
                .filter(\.$caregiverID == currentUserID)
                .first() else {
                throw Abort(.notFound, reason: "目前尚未綁定任何被照護者")
            }
            
            // 🛡️ 照護者代為管理排程時，校驗 canManageMedPlan
            if requireManagePermission && !bond.canManageMedPlan {
                throw Abort(.forbidden, reason: "被照護者尚未授權您建立或管理用藥排程清單")
            }
            
            return TargetContext(patientID: bond.patientID, operatorRole: currentUser.role)
        }
        
        return TargetContext(patientID: currentUserID, operatorRole: currentUser.role)
    }
    
    // MARK: - 1. 新增或更新用藥排程 (POST /medication-plan/save)
    @Sendable
    func savePlan(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        // 🔥 解析病患 ID 與操作者角色，並核對 canManageMedPlan
        let context = try await resolveTargetContext(req: req, currentUserID: payload.userID, requireManagePermission: true)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        struct PlanRequestDTO: Content {
            let id: Int?
            let name: String
            let dose: String
            let medType: String
            let defaultPatchRegion: String?
            let timeSlotsRaw: String
            let startDate: Date
            let repeatFrequency: String
            let customInterval: Int
            let customUnit: String
            let weekdaysRaw: String
            let monthDaysRaw: String
        }
        
        let data = try req.content.decode(PlanRequestDTO.self, using: decoder)
        
        if let planID = data.id, let existing = try await MedicationPlan.find(planID, on: req.db) {
            guard existing.userID == context.patientID else {
                throw Abort(.forbidden, reason: "您無權修改此排程")
            }
            existing.name = data.name
            existing.dose = data.dose
            existing.medType = data.medType
            existing.defaultPatchRegion = data.defaultPatchRegion
            existing.timeSlotsRaw = data.timeSlotsRaw
            existing.startDate = data.startDate
            existing.repeatFrequency = data.repeatFrequency
            existing.customInterval = data.customInterval
            existing.customUnit = data.customUnit
            existing.weekdaysRaw = data.weekdaysRaw
            existing.monthDaysRaw = data.monthDaysRaw
            // 修改排程時保留原建立者角色 (creatorRole 不更動)
            try await existing.update(on: req.db)
        } else {
            // 🔒 新建排程時由後端自動指定 creatorRole
            let newPlan = MedicationPlan(
                userID: context.patientID,
                name: data.name,
                dose: data.dose,
                medType: data.medType,
                defaultPatchRegion: data.defaultPatchRegion,
                timeSlotsRaw: data.timeSlotsRaw,
                startDate: data.startDate,
                repeatFrequency: data.repeatFrequency,
                customInterval: data.customInterval,
                customUnit: data.customUnit,
                weekdaysRaw: data.weekdaysRaw,
                monthDaysRaw: data.monthDaysRaw,
                creatorRole: context.operatorRole // 🔥 自動標記 0 或 1
            )
            try await newPlan.create(on: req.db)
        }
        return .ok
    }
    
    // MARK: - 2. 取得所有用藥排程清單 (GET /medication-plan/all)
    @Sendable
    func getAllPlans(req: Request) async throws -> [MedicationPlan] {
        let payload = try req.auth.require(UserPayload.self)
        let context = try await resolveTargetContext(req: req, currentUserID: payload.userID, requireManagePermission: false)
        
        return try await MedicationPlan.query(on: req.db)
            .filter(\.$userID == context.patientID)
            .sort(\.$createdAt, .descending)
            .all()
    }
    
    // MARK: - 3. 刪除用藥排程 (DELETE /medication-plan/:planID)
    @Sendable
    func deletePlan(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(UserPayload.self)
        let context = try await resolveTargetContext(req: req, currentUserID: payload.userID, requireManagePermission: true)
        
        guard let planID = req.parameters.get("planID", as: Int.self) else {
            throw Abort(.badRequest, reason: "無效的排程 ID")
        }
        
        guard let plan = try await MedicationPlan.query(on: req.db)
            .filter(\.$id == planID)
            .filter(\.$userID == context.patientID)
            .first() else {
            throw Abort(.notFound, reason: "找不到該筆排程或無權限刪除")
        }
        
        try await plan.delete(on: req.db)
        return .noContent
    }
}
