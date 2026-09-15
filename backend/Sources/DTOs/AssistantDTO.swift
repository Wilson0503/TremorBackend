import Vapor
import Foundation

struct DailyRequestDTO: Content {
    let id: String         // 承接前端 SwiftData 的 UUID 字串
    let content: String
    let date: Date
    let colorHex: String
    let sender: String
    let moodName: String?
    let isCaregiverOnly: Bool?
}

// 🌟 補齊 userID 並增加 typealias 相容 App 端命名
struct DailyResponseDTO: Content {
    let id: String
    let userID: Int?
    let content: String
    let date: Date
    let colorHex: String
    let sender: String
    let moodName: String?
    let isCaregiverOnly: Bool
}

typealias DailyRecordResponseDTO = DailyResponseDTO
