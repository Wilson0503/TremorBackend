import Fluent
import Vapor
import Foundation

final class TremorTrendPoint: Model, Content, @unchecked Sendable {
    static let schema = "tremor_trend_points"
    
    @ID(custom: .id) var id: UUID?
    @Field(key: "user_id") var userID: Int
    @Field(key: "session_id") var sessionId: String
    @Field(key: "recorded_at") var recordedAt: Date
    @Field(key: "rms_value") var rmsValue: Double
    @Field(key: "dominant_frequency_hz") var dominantFrequencyHz: Double?
    @Field(key: "motor_on_fraction") var motorOnFraction: Double
    @Field(key: "data_valid") var dataValid: Bool
    @Field(key: "frequency_reliable") var frequencyReliable: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    
    init() {}
    
    init(
        id: UUID,
        userID: Int,
        sessionId: String,
        recordedAt: Date,
        rmsValue: Double,
        dominantFrequencyHz: Double?,
        motorOnFraction: Double,
        dataValid: Bool,
        frequencyReliable: Bool
    ) {
        self.id = id
        self.userID = userID
        self.sessionId = sessionId
        self.recordedAt = recordedAt
        self.rmsValue = rmsValue
        self.dominantFrequencyHz = dominantFrequencyHz
        self.motorOnFraction = motorOnFraction
        self.dataValid = dataValid
        self.frequencyReliable = frequencyReliable
    }
}
