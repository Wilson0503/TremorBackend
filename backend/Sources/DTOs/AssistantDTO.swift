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
    
    enum CodingKeys: String, CodingKey {
        case id, content, date, sender
        case colorHex
        case colorHexSnake = "color_hex"
        case moodName
        case moodNameSnake = "mood_name"
        case isCaregiverOnly
        case isCaregiverOnlySnake = "is_caregiver_only"
    }
    
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.content = try container.decode(String.self, forKey: .content)
        self.date = try container.decode(Date.self, forKey: .date)
        self.sender = try container.decode(String.self, forKey: .sender)
        
        // 雙向相容 colorHex 與 color_hex
        if let color = try container.decodeIfPresent(String.self, forKey: .colorHexSnake) {
            self.colorHex = color
        } else {
            self.colorHex = try container.decode(String.self, forKey: .colorHex)
        }
        
        // 雙向相容 moodName 與 mood_name
        if let mood = try container.decodeIfPresent(String.self, forKey: .moodNameSnake) {
            self.moodName = mood
        } else {
            self.moodName = try container.decodeIfPresent(String.self, forKey: .moodName)
        }
        
        // 🔥 核心修正：雙向相容 is_caregiver_only 與 isCaregiverOnly
        if let isCaregiver = try container.decodeIfPresent(Bool.self, forKey: .isCaregiverOnlySnake) {
            self.isCaregiverOnly = isCaregiver
        } else {
            self.isCaregiverOnly = try container.decodeIfPresent(Bool.self, forKey: .isCaregiverOnly)
        }
    }
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(date, forKey: .date)
        try container.encode(colorHex, forKey: .colorHex)
        try container.encode(sender, forKey: .sender)
        try container.encodeIfPresent(moodName, forKey: .moodName)
        try container.encodeIfPresent(isCaregiverOnly, forKey: .isCaregiverOnly)
    }
}

// 補齊 userID 與別名相容
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
