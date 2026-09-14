import Vapor
import Foundation

// 1. 接收原始 IMU 數據的 DTO (壓縮版)
struct RawTremorUploadRequest: Content {
    let sessionId: String
    let sampleCount: Int
    let compressedData: Data
}

// 2. 接收 0.5 秒演算法分析結果的 DTO (維持不變)
struct TremorAnalysisUploadRequest: Content {
    let id: UUID
    let sessionId: String
    let recordedAt: Date
    let dominantFrequencyHz: Double?
    let tremorStrengthRmsDps: Double?
    let motorOnFraction: Double
    let dataValid: Bool
    let frequencyReliable: Bool
    let activityTag: String
    let note: String?
}

// 3. 回傳週報/分析時使用的 Response DTO (維持不變)
struct TrendPoint: Content {
    let date: Date
    let averageFrequency: Double
    let averageAmplitude: Double
}
// 4. 更新震顫分析紀錄標籤與備註 DTO (雙向相容 camelCase 與 snake_case)
struct UpdateTremorAnalysisRequestDTO: Content {
    let activityTag: String?
    let note: String?
    
    enum CodingKeys: String, CodingKey {
        case activityTag
        case activityTagSnake = "activity_tag"
        case note
    }
    
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // 優先讀取 activity_tag (snake_case)，若無則讀取 activityTag (camelCase)
        if let tagSnake = try container.decodeIfPresent(String.self, forKey: .activityTagSnake) {
            self.activityTag = tagSnake
        } else {
            self.activityTag = try container.decodeIfPresent(String.self, forKey: .activityTag)
        }
        
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
    }
    
    // 補上手動 encode 實作以滿足 Content (Encodable) 規範
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.activityTag, forKey: .activityTag)
        try container.encodeIfPresent(self.note, forKey: .note)
    }
}
