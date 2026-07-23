import Fluent
import Vapor
import Foundation

final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"
    
    @ID(custom: .id) var id: Int?
    @Field(key: "email") var email: String
    @Field(key: "password_hash") var passwordHash: String
    @Field(key: "birth") var birth: Date?
    @Field(key: "name") var name: String?
    @Field(key: "gender") var gender: Int?
    @Field(key: "disease_stage") var diseaseStage: String?
    @Field(key: "pairing_code") var pairingCode: String?
    @Field(key: "pairing_code_expires_at") var pairingCodeExpiresAt: Date?
    // 🔥 新增這行
    @Field(key: "active_session_id") var activeSessionID: String?
    @Field(key: "role") var role: Int // 0: 被照護者, 1: 照護者
    
    init() {}
    
    init(
        id: Int? = nil,
        email: String,
        passwordHash: String,
        birth: Date? = nil,
        name: String? = nil,
        gender: Int? = nil,
        diseaseStage: String? = nil,
        pairingCode: String? = nil,
        pairingCodeExpiresAt: Date? = nil,
        role: Int = 0 // 💡 預設為 0
    ) {
        self.id = id
        self.email = email
        self.passwordHash = passwordHash
        self.birth = birth
        self.name = name
        self.gender = gender
        self.diseaseStage = diseaseStage
        self.pairingCode = pairingCode
        self.pairingCodeExpiresAt = pairingCodeExpiresAt
        self.role = role // 🔥 賦值
    }
    
    func toResponse() -> UserResponse {
        return UserResponse(
            id: self.id,
            email: self.email,
            name: self.name,
            birth: self.birth,
            gender: self.gender,
            diseaseStage: self.diseaseStage,
            pairingCode: self.pairingCode,
            pairingCodeExpiresAt: self.pairingCodeExpiresAt,
            role: self.role // 🔥 傳遞給前端 DTO
        )
    }
}
