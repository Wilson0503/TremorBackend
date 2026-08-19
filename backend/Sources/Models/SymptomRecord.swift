import Fluent
import Vapor
import Foundation

final class SymptomRecord: Model, Content, @unchecked Sendable {
    static let schema = "symptom_records"

    @ID(custom: .id)
    var id: Int?

    @Field(key: "user_id")
    var userID: Int

    @Field(key: "date")
    var date: Date

    @Field(key: "symptom_note")
    var symptomNote: String

    // 儲存多媒體二進位陣列
    @Field(key: "media_data_list")
    var mediaDataList: [Data]

    @Field(key: "is_video")
    var isVideo: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(id: Int? = nil, userID: Int, date: Date, symptomNote: String, mediaDataList: [Data] = [], isVideo: Bool = false) {
        self.id = id
        self.userID = userID
        self.date = date
        self.symptomNote = symptomNote
        self.mediaDataList = mediaDataList
        self.isVideo = isVideo
    }
}
