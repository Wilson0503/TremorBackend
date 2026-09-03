import Fluent
import Vapor
import Foundation

final class UserBond: Model, Content, @unchecked Sendable {
    static let schema = "user_bonds"
    
    @ID(custom: .id)
    var id: Int?
    
    @Field(key: "caregiver_id")
    var caregiverID: Int
    
    @Field(key: "patient_id")
    var patientID: Int
    
    // 🔥 新增：用藥授權權限欄位 (預設 false)
    @Field(key: "can_manage_med_plan")
    var canManageMedPlan: Bool
    
    @Field(key: "can_add_med_record")
    var canAddMedRecord: Bool
    
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    init() { }
    
    init(
        id: Int? = nil,
        caregiverID: Int,
        patientID: Int,
        canManageMedPlan: Bool = false,
        canAddMedRecord: Bool = false
    ) {
        self.id = id
        self.caregiverID = caregiverID
        self.patientID = patientID
        self.canManageMedPlan = canManageMedPlan
        self.canAddMedRecord = canAddMedRecord
    }
}
