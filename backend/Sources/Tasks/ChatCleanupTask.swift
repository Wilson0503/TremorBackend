import Vapor
import Fluent

struct ChatCleanupTask: LifecycleHandler {
    // 當 Vapor 伺服器成功啟動後，這個函式會被觸發
    func didBoot(_ app: Application) throws {
        app.logger.info("🕒 啟動對話紀錄定期清理背景任務 (自動刪除 6 個月前資料)")
        
        // 開啟一個獨立的背景 Task，不影響原本 API 的運作
        Task {
            while !Task.isCancelled {
                do {
                    // 1. 計算出「確切的 6 個月前」是哪一天
                    guard let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: Date()) else {
                        return
                    }
                    
                    // 2. 先計算有幾筆即將被刪除 (單純為了 Log 紀錄)
                    let expiredCount = try await ChatHistory.query(on: app.db)
                        .filter(\.$createdAt < sixMonthsAgo)
                        .count()
                    
                    // 3. 執行 Fluent 刪除指令
                    if expiredCount > 0 {
                        try await ChatHistory.query(on: app.db)
                            .filter(\.$createdAt < sixMonthsAgo)
                            .delete()
                        
                        app.logger.info("🗑️ [自動清理] 已成功刪除 \(expiredCount) 筆超過 6 個月的對話紀錄。")
                    }
                    
                    // 4. 讓這個背景任務休眠 24 小時 (86400 秒)，明天再起來檢查一次
                    // Swift 的 Task.sleep 單位是奈秒 (Nanoseconds)
                    try await Task.sleep(nanoseconds: 24 * 60 * 60 * 1_000_000_000)
                    
                } catch {
                    app.logger.error("自動清理對話紀錄發生錯誤：\(error)")
                    // 萬一資料庫連線不穩報錯，休眠 1 小時後再試，避免無限報錯迴圈
                    try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
                }
            }
        }
    }
}
