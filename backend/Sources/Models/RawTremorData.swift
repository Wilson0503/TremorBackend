import Fluent
import Vapor
import Foundation

final class RawTremorData: Model, Content, @unchecked Sendable {
    static let schema = "raw_tremor_data"

    @ID(custom: .id) var id: Int?
    @Field(key: "user_id") var userID: Int
    @Field(key: "session_id") var sessionId: String
    @Field(key: "sequence") var sequence: Int              // 👈 修改為 Int
    @Field(key: "sample_tick_ms") var sampleTickMs: Int    // 👈 修改為 Int
    @Field(key: "gyro_x_dps") var gyroXDps: Double
    @Field(key: "gyro_y_dps") var gyroYDps: Double
    @Field(key: "gyro_z_dps") var gyroZDps: Double
    @Field(key: "sensor_valid") var sensorValid: Int       // 👈 修改為 Int
    @Field(key: "motor_enabled") var motorEnabled: Int     // 👈 修改為 Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() { }

    init(userID: Int, sessionId: String, sequence: Int, sampleTickMs: Int, gyroXDps: Double, gyroYDps: Double, gyroZDps: Double, sensorValid: Int, motorEnabled: Int) {
        self.userID = userID
        self.sessionId = sessionId
        self.sequence = sequence
        self.sampleTickMs = sampleTickMs
        self.gyroXDps = gyroXDps
        self.gyroYDps = gyroYDps
        self.gyroZDps = gyroZDps
        self.sensorValid = sensorValid
        self.motorEnabled = motorEnabled
    }
}
