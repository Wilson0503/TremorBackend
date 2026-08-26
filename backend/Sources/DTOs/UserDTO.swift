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

// 🌟 修改：補上 bondID 與 caregiverID，方便前端 App 辨識與操作
struct CaregiverListResponseDTO: Content {
    let bondID: Int
    let caregiverID: Int
    let partnerName: String
    let partnerEmail: String
}

struct SinglePatientResponseDTO: Content {
    let partnerName: String
    let partnerEmail: String
}

struct UpdateProfileRequestDTO: Content {
    let name: String?
    let birth: Date?
    let gender: Int?
    let diseaseStage: String?
    let oldPassword: String?
    let newPassword: String?
}

// 🌟 新增：解除綁定專用 Request DTO (支援 Email 或 ID)
struct UnlinkBondRequestDTO: Content {
    let caregiverEmail: String?
    let caregiverID: Int?
}
