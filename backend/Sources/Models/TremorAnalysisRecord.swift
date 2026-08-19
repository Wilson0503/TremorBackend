import Fluent
import Vapor
import Foundation

final class TremorAnalysisRecord: Model, Content, @unchecked Sendable {
    static let schema = "tremor_analysis_records"

    @ID(custom: .id) var id: UUID?
    @Field(key: "user_id") var userID: Int
    @Field(key: "session_id") var sessionId: String
    
    // 轉換為 Vapor 常用的 Date 型別以便後續時間搜尋
    @Field(key: "recorded_at") var recordedAt: Date
    @Field(key: "dominant_frequency_hz") var dominantFrequencyHz: Double?
    @Field(key: "tremor_strength_rms_dps") var tremorStrengthRmsDps: Double?
    @Field(key: "motor_on_fraction") var motorOnFraction: Double
    @Field(key: "data_valid") var dataValid: Bool
    @Field(key: "frequency_reliable") var frequencyReliable: Bool
    @Field(key: "activity_tag") var activityTag: String
    @Field(key: "note") var note: String?

    init() { }

    init(id: UUID, userID: Int, sessionId: String, recordedAt: Date, dominantFrequencyHz: Double?, tremorStrengthRmsDps: Double?, motorOnFraction: Double, dataValid: Bool, frequencyReliable: Bool, activityTag: String, note: String?) {
        self.id = id
        self.userID = userID
        self.sessionId = sessionId
        self.recordedAt = recordedAt
        self.dominantFrequencyHz = dominantFrequencyHz
        self.tremorStrengthRmsDps = tremorStrengthRmsDps
        self.motorOnFraction = motorOnFraction
        self.dataValid = dataValid
        self.frequencyReliable = frequencyReliable
        self.activityTag = activityTag
        self.note = note
    }
}
