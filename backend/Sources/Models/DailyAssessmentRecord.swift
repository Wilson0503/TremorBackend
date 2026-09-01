import Fluent
import Vapor
import Foundation

final class DailyAssessmentRecord: Model, Content, @unchecked Sendable {
    static let schema = "daily_assessment_records"

    @ID(custom: .id)
    var id: Int?

    @Field(key: "user_id")
    var userID: Int

    @Field(key: "date")
    var date: Date

    @Field(key: "total_score")
    var totalScore: Int

    @Field(key: "mood_score")
    var moodScore: Int

    @Field(key: "adl_score")
    var adlScore: Int

    @Field(key: "motor_score")
    var motorScore: Int

    @OptionalField(key: "details_json")
    var detailsJson: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(
        id: Int? = nil,
        userID: Int,
        date: Date,
        totalScore: Int,
        moodScore: Int,
        adlScore: Int,
        motorScore: Int,
        detailsJson: String? = nil
    ) {
        self.id = id
        self.userID = userID
        self.date = date
        self.totalScore = totalScore
        self.moodScore = moodScore
        self.adlScore = adlScore
        self.motorScore = motorScore
        self.detailsJson = detailsJson
    }
}
