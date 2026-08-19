import Fluent
import Vapor
import Foundation

final class DailyRecord: Model, Content, @unchecked Sendable {
    static let schema = "daily_records"
    
    @ID(custom: .id)
    var id: String? // 用 String 承接 UUID
    
    @Field(key: "user_id")
    var userID: Int
    
    @Field(key: "content")
    var content: String
    
    @Field(key: "date")
    var date: Date
    
    @Field(key: "color_hex")
    var colorHex: String
    
    @Field(key: "sender")
    var sender: String
    
    @Field(key: "mood_name")
    var moodName: String?
    
    @Field(key: "is_caregiver_only")
    var isCaregiverOnly: Bool
    
    init() { }
    
    init(id: String, userID: Int, content: String, date: Date, colorHex: String, sender: String, moodName: String? = nil, isCaregiverOnly: Bool = false) {
        self.id = id
        self.userID = userID
        self.content = content
        self.date = date
        self.colorHex = colorHex
        self.sender = sender
        self.moodName = moodName
        self.isCaregiverOnly = isCaregiverOnly
    }
}
