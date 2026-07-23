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
    let role: Int // 🔥 新增這行，讓前端 SwiftUI 知道目前登入者的身份
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

// 🔥 將原本的 LinkedPatientResponseDTO 改為 LinkedPartnerResponseDTO (通用夥伴資訊)
struct LinkedPartnerResponseDTO: Content {
    let bondID: Int
    let partnerID: Int
    let partnerName: String
    let partnerEmail: String
    let partnerRole: Int // 0: 被照護者, 1: 照護者
}
