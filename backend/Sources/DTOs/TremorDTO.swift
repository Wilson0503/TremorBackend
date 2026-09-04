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
