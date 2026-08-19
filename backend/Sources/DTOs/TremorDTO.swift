import Vapor
import Foundation

// 1. 接收原始 IMU 數據的 DTO (支援批次上傳)
struct RawTremorUploadRequest: Content {
    let sessionId: String
    let points: [RawPoint]
    
    struct RawPoint: Content {
        let sequence: Int          // 👈 修改為 Int
        let sampleTickMs: Int      // 👈 修改為 Int
        let gyroXDps: Double
        let gyroYDps: Double
        let gyroZDps: Double
        let sensorValid: Int       // 👈 修改為 Int
        let motorEnabled: Int      // 👈 修改為 Int
    }
}

// 2. 接收 0.5 秒演算法分析結果的 DTO
struct TremorAnalysisUploadRequest: Content {
    let id: UUID
    let sessionId: String
    let recordedAtUtcMs: Int64
    let dominantFrequencyHz: Double?
    let tremorStrengthRmsDps: Double?
    let motorOnFraction: Double
    let dataValid: Bool
    let frequencyReliable: Bool
    let activityTag: String
    let note: String?
}

// 3. 回傳週報/分析時使用的 Response DTO (維持原樣)
struct TrendPoint: Content {
    let date: Date
    let averageFrequency: Double
    let averageAmplitude: Double
}
