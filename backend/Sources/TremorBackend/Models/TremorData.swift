import Fluent
import Vapor
import Foundation

final class TremorData: Model, Content, @unchecked Sendable {
    static let schema = "tremor_data"

    @ID(custom: .id)
    var id: Int?

    // 關聯到使用者 ID
    @Field(key: "user_id")
    var userID: Int

    @Field(key: "timestamp")
    var timestamp: Date?

    // IMU 感測器數據 (對應你 SQL 的 FLOAT 型別)
    @Field(key: "acc_x") var accX: Double
    @Field(key: "acc_y") var accY: Double
    @Field(key: "acc_z") var accZ: Double
    @Field(key: "gyro_x") var gyroX: Double
    @Field(key: "gyro_y") var gyroY: Double
    @Field(key: "gyro_z") var gyroZ: Double

    // 預留給分析後的欄位
    @Field(key: "tremor_frequency") var tremorFrequency: Double?
    @Field(key: "amplitude") var amplitude: Double?

    init() { }

    init(id: Int? = nil, userID: Int, accX: Double, accY: Double, accZ: Double, gyroX: Double, gyroY: Double, gyroZ: Double) {
        self.id = id
        self.userID = userID
        self.timestamp = Date() // 存入時自動標記時間
        self.accX = accX
        self.accY = accY
        self.accZ = accZ
        self.gyroX = gyroX
        self.gyroY = gyroY
        self.gyroZ = gyroZ
    }
}
