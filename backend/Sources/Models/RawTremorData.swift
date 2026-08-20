import Fluent
import Vapor
import Foundation

final class RawTremorData: Model, Content, @unchecked Sendable {
    static let schema = "raw_tremor_data"

    @ID(custom: .id) var id: Int?
    @Field(key: "user_id") var userID: Int
    @Field(key: "session_id") var sessionId: String
    @Field(key: "sample_count") var sampleCount: Int          // 記錄此包點數 (固定 400)
    @Field(key: "compressed_data") var compressedData: Data   // 壓縮後的二進位數據
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() { }

    init(id: Int? = nil, userID: Int, sessionId: String, sampleCount: Int, compressedData: Data) {
        self.id = id
        self.userID = userID
        self.sessionId = sessionId
        self.sampleCount = sampleCount
        self.compressedData = compressedData
    }
}
