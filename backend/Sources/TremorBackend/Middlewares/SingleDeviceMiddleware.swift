import Vapor
import Fluent

struct SingleDeviceMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        
        // 1. 取得這張 Token 裡面的 Payload 資訊 (剛剛加的 userID 和 sessionID)
        let payload = try request.auth.require(UserPayload.self)
        
        // 2. 去資料庫把這個人最新的資料撈出來
        guard let user = try await User.find(payload.userID, on: request.db) else {
            throw Abort(.unauthorized, reason: "找不到該帳號")
        }
        
        // 3. 🔥 關鍵防禦：比對 Token 內的 Session ID 與資料庫最新的是否吻合？
        guard let dbSessionID = user.activeSessionID, dbSessionID == payload.sessionID else {
            // 如果不吻合，代表有人在別台手機重新登入了，把舊裝置無情踢下線！
            throw Abort(.unauthorized, reason: "您的帳號已在其他裝置登入，請重新登入。")
        }
        
        // 4. 比對成功，放行，讓請求繼續往下走
        return try await next.respond(to: request)
    }
}
