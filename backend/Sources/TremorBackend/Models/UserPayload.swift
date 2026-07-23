import Vapor
import JWT

// 這就是通行證的內容定義
struct UserPayload: JWTPayload, Authenticatable {
    // 這裡紀錄這張通行證是屬於哪個 user 的 ID
    var userID: Int
    
    // 🔥 新增：把這一次登入產生的 Session ID 包進 Token 裡
    var sessionID: String
    
    // JWT 規範必備：過期時間
    var exp: ExpirationClaim

    // 驗證 Token 是否過期
    func verify(using signer: JWTSigner) throws {
        try self.exp.verifyNotExpired()
    }
}
