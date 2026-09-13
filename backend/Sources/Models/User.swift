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
    @Field(key: "active_session_id") var activeSessionID: String?
    @Field(key: "role") var role: Int
    @OptionalField(key: "avatar_data") var avatarData: Data? // 🔥 新增頭貼欄位
    // 在 activeSessionID 之後加入：
    @OptionalField(key: "reset_code") var resetCode: String?
    @OptionalField(key: "reset_code_expires_at") var resetCodeExpiresAt: Date?
    
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
        role: Int = 0,
        avatarData: Data? = nil // 🔥
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
        self.role = role
        self.avatarData = avatarData
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
            role: self.role,
            avatarData: self.avatarData // 🔥 傳回給 App
        )
    }
}
