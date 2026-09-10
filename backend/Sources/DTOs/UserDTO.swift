import Vapor
import Foundation

struct UserResponse: Content {
    let id: Int?
    let email: String
    let name: String?
    let birth: Date?
    let gender: Int?
    let diseaseStage: String?
    let pairingCode: String?
    let pairingCodeExpiresAt: Date?
    let role: Int
    let avatarData: Data? // 🔥 新增
}

struct LoginResponse: Content {
    let token: String
    let user: UserResponse
}

struct PairingCodeResponseDTO: Content {
    let pairingCode: String
    let expiresAt: Date
}

struct LinkPatientRequestDTO: Content {
    let patientEmail: String
    let pairingCode: String
}

struct LinkedPartnerResponseDTO: Content {
    let bondID: Int
    let partnerID: Int
    let partnerName: String
    let partnerEmail: String
    let partnerRole: Int
}

// 🌟 修改：補上權限欄位（供病患端清單顯示各照護者開關）
struct CaregiverListResponseDTO: Content {
    let bondID: Int
    let caregiverID: Int
    let partnerName: String
    let partnerEmail: String
    let canManageMedPlan: Bool // 🔥 新增
    let canAddMedRecord: Bool  // 🔥 新增
}

// 🌟 修改：補上權限欄位（供照護者端知道自己被賦予哪些權限，控制 UI 按鈕顯示）
struct SinglePatientResponseDTO: Content {
    let partnerName: String
    let partnerEmail: String
    let canManageMedPlan: Bool // 🔥 新增
    let canAddMedRecord: Bool  // 🔥 新增
}

// 🌟 新增：病患修改照護者權限專用 Request DTO
struct UpdateBondPermissionsRequestDTO: Content {
    let caregiverID: Int
    let canManageMedPlan: Bool?
    let canAddMedRecord: Bool?
}
struct UpdateProfileRequestDTO: Content {
    let name: String?
    let birth: Date?
    let gender: Int?
    let diseaseStage: String?
    let oldPassword: String?
    let newPassword: String?
    let avatarData: Data? // 🔥 新增
}

// 🌟 新增：解除綁定專用 Request DTO (支援 Email 或 ID)
struct UnlinkBondRequestDTO: Content {
    let caregiverEmail: String?
    let caregiverID: Int?
}
