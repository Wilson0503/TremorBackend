import Vapor
import Foundation

struct DailyRequestDTO: Content {
    let id: String         // 承接前端 SwiftData 的 UUID 字串
    let content: String
    let date: Date
    let colorHex: String
    let sender: String
    let moodName: String?
}

struct DailyResponseDTO: Content {
    let id: String
    let content: String
    let date: Date
    let colorHex: String
    let sender: String
    let moodName: String?
}
